#!/usr/bin/env ruby

require "pp"
require "net/https"
require "net/http"
require "json"
require "time"
require "getoptlong"

$api_key = "somekey"
all_servers = Array.new
$link = "https://api.newrelic.com/v2/servers.json?page=1"

DAY = 86400
HOUR = 3600
MINUTE = 60

#days = 7
#seconds = days * DAY

#hours = 1
#seconds = hours * HOUR

minutes = 20
seconds = minutes * MINUTE

to_prune = Array.new
to_keep = Array.new
dryrun = 0

def log_text(type, text)
	fixed_type = type.downcase.slice(0,1).capitalize + type.slice(1..-1)
	puts("[#{fixed_type}] #{text}")
	exit if type =~ /^fatal$/i
end

def validate_json(string)
	hashref = JSON.parse(string)
	return hashref
rescue JSON::ParserError
	return nil
end

def fetch(http_method, url, content)
	#puts "Fetching #{url}.."
	req = nil
	uri = URI(url)
	http = Net::HTTP.new(uri.host, uri.port)
	http.use_ssl = true
	http.verify_mode = OpenSSL::SSL::VERIFY_NONE
	http.read_timeout = 10
	
	if (http_method =~ /^get$/i)
		req = Net::HTTP::Get.new(uri.request_uri)
	elsif (http_method =~ /^delete$/i)
		req = Net::HTTP::Delete.new(uri.request_uri)
	end

	req["X-Api-Key"] = $api_key
	res = http.request(req)

	if (res.code.to_i == 200)
		body = validate_json(res.body)
		return {
			"body" => body,
			"headers" => res.to_hash
		}
	end
end

while ($link != nil)
	res = fetch("get", $link, nil)
	if (res["body"].has_key?("servers"))
		res["body"]["servers"].each do |server|
			all_servers.push(server)
		end
	end
	$link = nil
	if (res["headers"].has_key?("link"))
		links = res["headers"]["link"].first.split(/\s*,\s*/)
		links.each do |link|
			url, rel = link.split(/\s*;\s*/)
			url = url.gsub(/[<>]/, "")
			rel = rel.split(/=/)[1].gsub(/"/, "")
			if (rel == "next")
				$link = url
			end
		end
	else
		$link = nil
	end
end

all_servers.each do |server_obj|
	unix_time = Time.parse(server_obj["last_reported_at"]).to_i
	if ( (Time.now.to_i - unix_time) > seconds )
		to_prune.push(server_obj)
		#puts(sprintf("Pruning %s", server_obj["name"]))
	else
		to_keep.push(server_obj)
		#puts(sprintf("Keeping %s", server_obj["name"]))
	end
end

puts "Keeping #{to_keep.length} servers and pruning #{to_prune.length} servers."
puts "Pruning...."
to_prune.each do |server_obj|
	# 10.82.86.21_lms_e2e_splunk_indexer_us-west-2c
	server_name = server_obj["name"]
	#if server_name =~ (/_lms_[a-z0-9]+_splunk/)
		if (dryrun == 1)
			log_text("dryrun", "Pruning #{server_name}")
		else
			log_text("info", "Pruning #{server_name}")
			url = sprintf("https://api.newrelic.com/v2/servers/%s.json", server_obj["id"])
			res = fetch("delete", url, nil)
		end
	#end
end
