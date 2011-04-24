require 'spec_helper'
require 'dm-timestamps'

describe DataMapper::Adapters::GoogleSheetAdapter do
  use_vcr_cassette :record => :all

  class CrewMember
    include DataMapper::Resource

    property :id,           Serial
    property :name,         String
    property :times_a_lady, Integer
    property :created_at,   DateTime
  end

  before :each do
    DataMapper.setup(:default,
      :adapter    => "google_sheet",
      :secret_key => GoogleSession.test_user_token,
      :domain     => GoogleSession.test_sheet_url)
    DataMapper.repository(:default) do
      DataMapper.finalize
      DataMapper.repository.auto_migrate!
    end
  end

  it "should start out empty" do
    CrewMember.all.to_a.should be_empty
  end

  it "should enable creating new records and reading them back" do
    DataMapper.repository(:default) do
      CrewMember.create(:name => "Mike Nelson", :times_a_lady => 8)
      mike = CrewMember.first.reload
      mike.name.should be == "Mike Nelson"
      mike.times_a_lady.should == 8
    end
  end

  it "should be able to query on conditions" do
    DataMapper.repository(:default) do
      mike  = CrewMember.create(:name => "Mike Nelson", :times_a_lady => 8)
      gypsy = CrewMember.create(:name => "Gypsy", :times_a_lady => 3)
      tom   = CrewMember.create(:name => "Tom Servo", :times_a_lady => 100)
      results = CrewMember.all(:times_a_lady.lt => 10)
      results.to_a.should have(2).records
      results.should include(mike)
      results.should include(gypsy)
      results.should_not include(tom)
    end
  end

  it "should be able to update records" do
    DataMapper.repository(:default) do
      mike  = CrewMember.create(:name => "Mike Nelson", :times_a_lady => 8)
      mike.update(:times_a_lady => 4)
      mike.reload
      mike.times_a_lady.should be == 4
    end
  end

  it "should be able to delete records" do
    DataMapper.repository(:default) do
      mike  = CrewMember.create(:name => "Mike Nelson", :times_a_lady => 8)
      mike.destroy
      CrewMember.all.should be_empty
    end
  end

end

