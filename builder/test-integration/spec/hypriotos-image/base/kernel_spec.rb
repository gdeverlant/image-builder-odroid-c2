require 'spec_helper'

describe command('uname -r') do
  its(:stdout) { should match /4.12.0-rc7-gx-117011-g14be5bf?+/ }
  its(:exit_status) { should eq 0 }
end

describe file('/lib/modules/4.12.0-rc7-gx-117011-g14be5bf/kernel') do
  it { should be_directory }
end
