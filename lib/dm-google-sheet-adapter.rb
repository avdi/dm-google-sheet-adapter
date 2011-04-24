require 'dm-migrations'
require 'dm-migrations/auto_migration'
require 'faraday'
require 'nokogiri'

module DataMapper
  module Adapters
    class GoogleSheetAdapter < DataMapper::Adapters::AbstractAdapter
      NAMESPACES = {
          "atom" => "http://www.w3.org/2005/Atom",
          "gs"   => "http://schemas.google.com/spreadsheets/2006",
          "gd"   => "http://schemas.google.com/g/2005",
          "gsx"  => "http://schemas.google.com/spreadsheets/2006/extended"
      }
      ATOM_TYPE = "application/atom+xml"
      LIST_FEED_REL = "http://schemas.google.com/spreadsheets/2006#listfeed"
      WORKSHEETS_FEED_REL = "http://schemas.google.com/spreadsheets/2006#worksheetsfeed"
      CELL_FEED_REL = "http://schemas.google.com/spreadsheets/2006#cellsfeed"
      POST_REL = "http://schemas.google.com/g/2005#post"

      module FeedHelpers
        private
        def entry_links(entry)
          links = entry.xpath("atom:link", NAMESPACES).map { |link_elt|
            Link.new(
                link_elt["href"],
                :rel   => link_elt["rel"],
                :rev   => link_elt["rev"],
                :title => link_elt["title"],
                :type  => link_elt["type"])
          }
          LinkSet.new(links)
        end
      end
      include FeedHelpers

      class AuthSub
        def initialize(app, token)
          @app = app
          @token = token
        end

        def call(env)
          env[:request_headers]['Authorization'] =
                  %(AuthSub token="#{@token}")
          @app.call(env)
        end
      end

      class ParseAtom < Faraday::Response::Middleware
        include FeedHelpers
        def on_complete(env)
          content_type = env[:response_headers]["Content-Type"]
          return unless content_type =~ /^#{Regexp.escape(ATOM_TYPE)}/
          super
          env[:links] = entry_links(env[:body].root)
          env[:body].xpath("/*/atom:entry", NAMESPACES).to_a.each do
            |entry_elt|
            (env[:entries] ||= EntryList.new) << Entry.new(
                entry_elt.at_xpath("atom:title", NAMESPACES).text,
                entry_links(entry_elt))
          end
          env[:body].extend(HasEntries)
          env[:body].entries = env[:entries]
        end

        def parse(body)
          Nokogiri::XML(body)
        end
      end

      class Entry < Struct.new(:title, :links)
        def to_s
          "<#{title}> #{url}"
        end

        def url
          links["self"].href
        end
      end

      module HasEntries
        def entries
          @entries ||= EntryList.new
        end

        def entries=(new_entries)
          @entries = new_entries
        end
      end

      class EntryList
        extend Forwardable
        include Enumerable

        def_delegators :@list, :<<, :each, :map, :collect, :detect, :inject,
                       :include?, :size, :length

        def initialize(*args)
          @list = Array.new(*args)
        end

        def [](pattern)
          detect{|entry| pattern === entry.title}
        end
      end

      class AddLinks < Faraday::Response::Middleware
        def call(env)
          env[:links] ||= LinkSet.new
          super(env)
        end

        def on_complete(env)
          env[:body].extend(HasLinks)
          env[:body].links = env[:links]
        end
      end

      class Link
        include Comparable
        attr_accessor :rel, :rev, :href, :title, :type

        alias_method :to_s, :href

        def initialize(href, options={})
          @href       = href
          options.each do |k,v|
            self.send("#{k}=", v)
          end
        end

        def <=>(other)
          [self.href, self.rel, self.rev, self.type]  <=>
              [other.href, other.rel, other.rev, self.type]
        end

        def follow(*args)
          connection.get(href, *args)
        end

      end

      class LinkSet
        extend Forwardable
        include Enumerable

        def_delegators :@set, :<<, :detect, :each, :map, :collect, :inject

        def initialize(*args)
          options      = args.last.is_a?(Hash) ? args.pop : {}
          @set         = Set.new(*args)
        end

        def add_link(*args)
          @set << Link.new(*args)
        end

        # Find link by relationship
        def [](rel)
          detect{|l| l.rel == rel}
        end
      end

      module HasLinks
        def links
          @links ||= LinkSet.new
        end

        def links=(new_links)
          @links = new_links
        end
      end

      def storage_exists?(storage_name)
        !!find_worksheet_by_name(storage_name)
      end

      def create_model_storage(model)
        return false if storage_exists?(model.storage_name(name))
        resp = connection.post(
                        worksheets_feed_link.href,
                        worksheet_xml_for_model(model),
                        "Content-Type" => ATOM_TYPE)
        cells_url = resp.body.links[CELL_FEED_REL].href
        column_names(model).each_with_index do |colname, index|
          cell_url = "#{cells_url}/R1C#{index + 1}"
          connection.put(
              cell_url,
              cell_xml(cell_url, colname, 1, index + 1),
              "Content-Type" => ATOM_TYPE,
              "If-Match" => "*")
        end
        resp
      end

      def upgrade_model_storage(model)
        raise NotImplementedError
      end

      def destroy_model_storage(model)
        storage_name = model.storage_name(name)
        return false unless storage_exists?(storage_name)
        worksheets.entries.select{|ws| ws.title == storage_name}.each do |ws|
          connection.delete(ws.links["self"].href) do |req|
            req.headers["If-Match"] = "*"
          end
        end
      end

      def field_naming_convention
        ->(property){property.name.to_s.gsub(/[^[:alnum:]]+/, '').downcase}
      end

      def create(resources)
        table_groups = group_resources_by_table(resources)
        table_groups.each do |table, resources|
          resources.each do |resource|
            initialize_serial(resource, worksheet_record_count(table) + 1)
            post_resource_to_worksheet(resource, table)
          end
        end
        resources.size
      end

      def read(query)
        worksheet_name = query.model.storage_name(name)
        list = worksheet_as_list(worksheet_name)
        resource_hashes = list_to_hashes(list, query.fields)
        query.filter_records(resource_hashes)
      end

      def each_resource_with_edit_url(collection)
        worksheet_name = collection.storage_name(name)
        list = worksheet_as_list(worksheet_name)
        model_key = collection.model.key
        collection.each do |resource|
          edit_url = resource_edit_url(list, resource, model_key)
          yield(resource, edit_url)
        end
      end

      def update(attributes, collection)
        each_resource_with_edit_url(collection) do |resource, edit_url|
          put_updated_resource(edit_url, resource)
        end
        attributes.size
      end

      def delete(collection)
        each_resource_with_edit_url(collection) do |resource, edit_url|
          connection.delete(edit_url, 'If-Match' => "*")
        end
        collection.size
      end

      def resource_edit_url(list, resource, model_key)
        matching_entry =  entry_corresponding_to_resource(list, resource, model_key)
        edit_url = entry_edit_link(matching_entry)
        edit_url
      end

      def put_updated_resource(url, resource)
        connection.put(url,
                       list_xml_for_resource(resource),
                       "Content-Type" => ATOM_TYPE,
                       "If-Match" => "*")
      end

      def entry_edit_link(entry)
        links = entry_links(entry)
        edit_url = links["edit"].href
        edit_url
      end

      def entry_corresponding_to_resource(list, resource, model_key)
        entries(list).detect { |entry|
          model_key.all? { |key_prop|
            cell = entry.at_xpath("gsx:#{key_prop.field}", NAMESPACES)
            cell_value = key_prop.typecast(cell.text)
            resource_value = resource.attribute_get(key_prop.name)
            cell_value == resource_value
          }
        }
      end

      def entries(list)
        list.xpath("/atom:feed/atom:entry", NAMESPACES)
      end

      def worksheet_record_count(worksheet)
        worksheet_as_list(worksheet).entries.size
      end

      def post_resource_to_worksheet(resource, worksheet)
        connection.post(
            post_link_for_worksheet(worksheet).href,
            list_xml_for_resource(resource),
            "Content-Type" => ATOM_TYPE)
      end

      def group_resources_by_table(resources)
        resources.group_by { |r| r.model.storage_name(name) }
      end

      def worksheet_as_list(worksheet_name)
        list_link = list_link_for_worksheet(worksheet_name)
        list = follow(list_link)
        list
      end

      def list_link_for_worksheet(worksheet_name)
        ws = find_worksheet_by_name(worksheet_name)
        list_link = ws.links[LIST_FEED_REL]
        list_link
      end

      def post_link_for_worksheet(worksheet_name)
        list = worksheet_as_list(worksheet_name)
        post_link = list.links[POST_REL]
        post_link
      end

      def find_worksheet_by_name(name_pattern)
        worksheets.entries[name_pattern]
      end

      def worksheets_feed_link
        spreadsheet.links[WORKSHEETS_FEED_REL]
      end

      def worksheets
        follow(worksheets_feed_link)
      end

      def spreadsheet
        connection.get(spreadsheet_path).body
      end

      def spreadsheet_path
        spreadsheet_url.path.to_s
      end

      def spreadsheet_url
        @spreadsheet_url ||= Addressable::URI.parse(options[:domain])
      end

      def site
        spreadsheet_url.site.to_s
      end

      def token
        options[:secret_key]
      end

      def connection
        @connection ||= begin
          Faraday.new(:url => site) do |b|
            b.use Faraday::Response::RaiseError
            b.use AuthSub, token
            b.use AddLinks
            b.use ParseAtom

            b.adapter connection_adapter
          end
        end
      end

      def connection_adapter
        options.fetch(:connection_adapter){:net_http}
      end

      def follow(link_or_url)
        connection.get(link_or_url.to_s).body
      end

      def column_names(model)
        properties = model.properties(name)
        column_names = properties.map do |p|
          model.field_naming_convention(name).call(p)
        end
        column_names
      end

      def worksheet_xml_for_model(model)
        column_names = column_names(model)
        column_count   = column_names.size
        worksheet_name = model.storage_name(name)

        Nokogiri::XML::Builder.new do |x|
          x.entry("xmlns"      => NAMESPACES["atom"],
                  "xmlns:gs"   => NAMESPACES["gs"]) {
            x.title(worksheet_name)
            x.send("gs:colCount", column_count)
            x.send("gs:rowCount", 1)
          }
        end.to_xml
      end

      def cell_xml(cell_url, value, row, col)
        Nokogiri::XML::Builder.new do |x|
          x.entry("xmlns"      => NAMESPACES["atom"],
                  "xmlns:gs"   => NAMESPACES["gs"],
                  "xmlns:gd"   => NAMESPACES["gd"]) {
            x.id_(cell_url)
            x.send("gs:cell", row: row, col: col, inputValue: value)
          }
        end.to_xml
      end

      def list_xml_for_resource(resource)
        Nokogiri::XML::Builder.new do |x|
          x.entry("xmlns"       => NAMESPACES["atom"],
                  "xmlns:gsx"   => NAMESPACES["gsx"]) {
            attrs = resource.attributes(:field)
            attrs.each do |field_name, value|
              x.send("gsx:#{field_name}", value.to_s)
            end
          }
        end.to_xml
      end

      def list_to_hashes(list, desired_fields)
        list.xpath("//atom:entry", NAMESPACES).inject([]) { |hashes, entry|
          attributes = desired_fields.inject({}) {|attrs, field|
            field_name = field.field
            value_elt = entry.at_xpath("gsx:#{field_name}", NAMESPACES)
            value = value_elt ? field.typecast(value_elt.text) : nil
            attrs.merge(field => value)
          }
          hashes << attributes
        }
      end
    end
  end
end
