# frozen_string_literal: true

RSpec.describe "library file layout" do
  it "defines at most one class per file" do
    offenders = Dir[File.expand_path("../lib/**/*.rb", __dir__)].filter_map do |file|
      source = File.read(file)
      declarations = source.scan(/^\s*class\s+(?!<<)/).size
      assignments = source.scan(/^\s*[A-Z]\w*\s*=\s*(?:Class|Data|Struct)\.(?:new|define)/).size
      count = declarations + assignments
      "#{file.delete_prefix("#{File.expand_path("..", __dir__)}/")}: #{count}" if count > 1
    end

    expect(offenders).to be_empty, "multiple classes found:\n#{offenders.join("\n")}"
  end
end
