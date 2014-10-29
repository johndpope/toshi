xml.instruct! :xml, :version => '1.0'
xml.rss :version => "2.0" do
  xml.channel do
    xml.title "Toshi latest blocks"
    xml.description "List of latest #{Toshi.settings[:network]} blocks"
    xml.link request.base_url

    @blocks.map(&:to_hash).each do |block|
      xml.item do
        xml.title block[:hash]
        xml.link "#{request.base_url}/api/v0/blocks/#{block[:height]}"
        xml.description "height: #{block[:height]}, transactions: #{block[:transactions_count]}, size: #{block[:size]}KB"
        xml.pubDate Time.parse(block[:time]).rfc822()
        xml.guid "#{request.base_url}/api/v0/blocks/#{block[:height]}"
      end
    end
  end
end