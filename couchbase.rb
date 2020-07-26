#!/usr/bin/env ruby
require "pp"
require "net/http"
require "net/https"
require "json"
require "quickbase"
require "logger"
require "yaml"
require "etc"
require "kconv"
require "optparse"
require "nokogiri"

class Logger
	def self.custom_level(tag)
		SEV_LABEL << tag
		idx = SEV_LABEL.size - 1

		define_method(tag.downcase.gsub(/\W+/, '_').to_sym) do |progname, &block|
			add(idx, nil, progname, &block)
		end
	end
	custom_level "DRYRUN"
end

def auth()
	printf("Corp username (#{Etc.getlogin}): ")
	username = STDIN.gets.chomp
	username = username.length > 1 ? username : Etc.getlogin

	printf("Password for #{username}: ")
	system "stty -echo"
	password = STDIN.gets.chomp
	system "stty echo"
	puts ""
	return {"username" => username || nil, "password" => password || nil}
end

def load_config(options, cfg_file)
	cfg = nil
	if (File.exists?(cfg_file))
		s = File.stat(cfg_file)
		mode = sprintf("%o", s.mode)
		unless (mode == "100600")
			options[:logger].fatal("The config file #{cfg_file} should be mode 0600 but it is not! Please fix this and try again.")
			exit 1
		end

		begin
			cfg = YAML.load_file(cfg_file)
		rescue Psych::SyntaxError => e
			options[:logger].fatal("An error occured reading the configuration file #{cfg_file}: #{e}")
			exit
		end
	else
		options[:logger].fatal("Configuration file #{cfg_file} not found.")
		exit
	end
	return cfg
end

def _validate_json(string)
	hashref = JSON.parse(string)
	return hashref
rescue JSON::ParserError
	return nil
end

def _couchbase_request(*args)
	http_method = args[0]
	url = args[1]
	cfg = args[2]
	options = args[3]
	http = nil

	method = caller[0][/`.*'/][1..-2]
	options[:logger].info(sprintf("Fetching %s", url))

	uri = URI(URI.escape(url))

	if (cfg["proxy"])
		proxy = URI.parse(cfg["proxy"])
		http = Net::HTTP.new(uri.host, uri.port, proxy.host, proxy.port)
	else
		http = Net::HTTP.new(uri.host, uri.port)
	end

	http.read_timeout = 180

	if (http_method =~ /^get$/i)
		req = Net::HTTP::Get.new(uri.request_uri)
	end

	req.basic_auth cfg["couchbase"]["username"], cfg["couchbase"]["password"]

	res = http.request(req)
	if (res.code =~ /^2\d\d$/)
		hashref = _validate_json(res.body);
		if (hashref)
			return hashref
		end
	end
end

def _newrelic_request(*args)
	http_method = args[0]
	url = args[1]
	cfg = args[2]
	options = args[3]
	http = nil

	method = caller[0][/`.*'/][1..-2]
	options[:logger].info(sprintf("Fetching %s", url))

	uri = URI(URI.escape(url))

	if (cfg["proxy"])
		proxy = URI.parse(cfg["proxy"])
		http = Net::HTTP.new(uri.host, uri.port, proxy.host, proxy.port)
	else
		http = Net::HTTP.new(uri.host, uri.port)
	end

	http.use_ssl = true
	http.verify_mode = ::OpenSSL::SSL::VERIFY_NONE
	http.read_timeout = 180

	if (http_method =~ /^get$/i)
		req = Net::HTTP::Get.new(uri.request_uri)
	end

	req["X-Api-Key"] = cfg["newrelic"]["key"]

	res = http.request(req)
	if (res.code =~ /^2\d\d$/)
		hashref = _validate_json(res.body);
		if (hashref)
			return hashref
		end
	end
end

def _generic_request(*args)
	http_method = args[0]
	url = args[1]
	content = args[2] || nil
	cfg = args[3]
	options = args[4]
	http = nil

	method = caller[0][/`.*'/][1..-2]
	options[:logger].info(sprintf("Fetching %s", url))

	uri = URI(URI.escape(url))

	if (cfg["proxy"])
		proxy = URI.parse(cfg["proxy"])
		http = Net::HTTP.new(uri.host, uri.port, proxy.host, proxy.port)
	else
		http = Net::HTTP.new(uri.host, uri.port)
	end

	http.read_timeout = 180

action = "http://metricsdata.webservicesimpl.server.introscope.wily.com"
action = ""
	if (http_method =~ /^get$/i)
		req = Net::HTTP::Get.new(uri.request_uri)
	elsif (http_method =~ /^post$/i)
		req = Net::HTTP::Post.new(uri.request_uri)
		req["Content-Type"] = "text/xml"
		req["SOAPAction"] = action
		req.basic_auth cfg["wily"]["username"], cfg["wily"]["password"]
		req.body = content
	end

	res = http.request(req)
puts res.code
puts res.body
exit
	if (res.code =~ /^2\d\d$/)
		return res.body
	end
end

def couchstats(colo_info, cfg, options)
	base_url = colo_info["base_url"]
	v = colo_info["v"]
	uuid = colo_info["uuid"]
	colo = colo_info["colo"].upcase
	# Initialize empty per-colo hash for the stats
	output = {
		"op/s #{colo}" => 0,
		"Cache Miss #{colo}" => 0,
		"% Active Docs #{colo}" => 0,
		"Disk Write Queue #{colo}" => 0,
		"Disk Fill #{colo}" => 0,
		"Disk Drain #{colo}" => 0,
		"CPU #{colo}" => 0,
		"Memory #{colo} in GB" => 0,
		"Disk IO #{colo}" => 0,
		"Number of Items #{colo}" => 0
	}
	taxreturn = Hash.new

	# Construct couchbase API URLs
	bucket_url = sprintf( "%s/pools/default/buckets/taxreturn/stats?zoom=minute", base_url)
	server_url = sprintf( "%s/pools/default/buckets?v=%s&uuid=%s&basic_stats=false", base_url, v, uuid)

	# Gather bucket stats and bucket info
	bucket_stats = _couchbase_request("get", bucket_url, cfg, options)
	single_bucket_info = _couchbase_request("get", server_url, cfg, options)

	# Find the the taxreturn bucket
	single_bucket_info.each do |bucket|
		taxreturn = bucket if bucket["name"] == "taxreturn"
	end

	# Look for taxreturn bucket stats/samples
	samples = bucket_stats["op"]["samples"]

	# Populate these values only if the samples exist
	if (samples)
		output["Cache Miss #{colo}"] = sprintf("%.1f%%", samples["ep_bg_fetched"].last / samples["cmd_get"].last * 100)
		output["% Active Docs #{colo}"] = sprintf("%.0f%%", samples["vb_active_resident_items_ratio"].last)
		output["Disk Write Queue #{colo}"] = sprintf("%.0f", samples["ep_queue_size"].last + samples["ep_flusher_todo"].last)
		output["Disk Fill #{colo}"] = sprintf("%.0f", samples["ep_diskqueue_fill"].last)
		output["Disk Drain #{colo}"] = sprintf("%.0f", samples["ep_diskqueue_drain"].last)
		output["Disk IO #{colo}"] = sprintf("%.1f%%", 0)
	end

	# Populate these values only if the taxreturn bucket exists
	if (taxreturn)
		cpu = 0
		mem = 0
		taxreturn["nodes"].each do |node|
			cpu = cpu + node["systemStats"]["cpu_utilization_rate"]
			mem = mem + node["interestingStats"]["mem_used"]
		end
		output["CPU #{colo}"] = sprintf("%.1f%%", cpu / taxreturn["nodes"].length)
		output["Memory #{colo} in GB"] = sprintf("%.1f", mem / 1024 / 1024 / 1024)

		output["Number of Items #{colo}"] = taxreturn["basicStats"]["itemCount"]
		output["op/s #{colo}"] = sprintf("%.0f", taxreturn["basicStats"]["opsPerSec"])
	end

	# Pull disk IO from newrelic
	nrdata = _newrelic_request("get", "https://api.newrelic.com/v2/servers.json?page=1", cfg, options)
	if (nrdata["servers"])
		prefix = nil
		array = Array.new
		if (colo == "QDC")
			prefix = "pprdsvpcs6"
		elsif (colo == "LVDC")
			prefix = "pprdsvpcs7"
		end
		nrdata["servers"].each do |server|
			if (server["host"] =~ /^#{prefix}/)
				array.push(server["summary"]["disk_io"])
			end
		end
		disk_io = 0
		array.each do |metric|
			disk_io = disk_io + metric
		end
		output["Disk IO #{colo}"] = sprintf("%.1f%%", disk_io / array.length)
	end
	return output
end

# Set variables
options = Hash.new
options[:logger] = Logger.new(STDOUT)
options[:logger].formatter = proc do |severity, datetime, progname, msg|
	sprintf("[%s] %s\n", severity.capitalize, msg)
end

optparse = OptionParser.new do |opts|
	opts.separator "Query the war room dashboard and update QuickBase"
	opts.on("-h", "--help", "Display this help.") do
		puts opts
		exit 0
	end

	opts.on("-n", "--dryrun", "Do not update QuickBase.") do |arg|
		options[:dryrun] = arg
	end
end

#if (ARGV.length == 0)
#	puts optparse
#	exit 1
#end

begin
	optparse.parse!
rescue OptionParser::ParseError => error
	options[:logger].fatal(error)
	exit 1
end

cfg_file = sprintf("%s/.couchbase.yml", Dir.home)
cfg = load_config(options, cfg_file)
qdc_io, lvdc_io = 0, 0
qb_user, qb_pass = nil

if (cfg["quickbase"]["username"] && cfg["quickbase"]["password"])
		qb_user, qb_pass = cfg["quickbase"]["username"], cfg["quickbase"]["password"]
else
		auth = auth()
		if (auth["username"].length > 0)
				qb_user = auth["username"]
		else
				options[:logger].fatal("missing username.")
				exit 1
		end

		if (auth["password"].length > 0)
				qb_pass = auth["password"]
		else
				options[:logger].fatal("missing password.")
				exit 1
		end
end

# Create the QuickBase object
qb = QuickBase.new({
	"env" => "prod",
	"username" => qb_user,
	"password" => qb_pass,
	"token" => cfg["quickbase"]["token"],
	"debug" => "on",
	"db" => cfg["quickbase"]["db"]
})

# Colo config array
config_data = [
	{
		"colo" => "qdc",
		"base_url" => "http://pprdsvpcs601.ie.intuit.net:8091",
		"uuid" => "4665fd3512c9cbfd663b1ebb0e68bd6b",
		"v" => "80586851"
	},
	{
		"colo" => "lvdc",
		"base_url" => "http://pprdsvpcs701.ie.intuit.net:8091",
		"uuid" => "6eb7e88fde7005b6a8c3f5c561335be7",
		"v" => "25908041"
	}
]

# Initialize empty hash for the output that will be used to update QuickBase
output = {"active users" => 0}

# Gather the couchbase stats for each colo
config_data.each do |colo|
	data = couchstats(colo, cfg, options)
	# Insert each item into the main output hash
	data.keys.each do |k|
		output[k] = data[k]
	end
end

# Gather active users using nokogiri
#content = _generic_request("get", "http://10.132.74.65:8080/ttolive/index_stage.xhtml", cfg, options)
#page = Nokogiri::HTML(content)
#tile_headers = page.css("div.TileHeader")
#tile_headers.each do |tile_header|
#	if (tile_header.text == "Active Users")
#		p = tile_header.next_element.css("p").first
#		if (p.text =~ /\s+([0-9,]+)\s/)
#			output["active users"] = $1.gsub(",", "")
#		end
#	end
#end
data = <<-EOF
<soapenv:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="http://metricsdata.webservicesimpl.server.introscope.wily.com">
   <soapenv:Header/>
   <soapenv:Body>
      <met:getLiveMetricData soapenv:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
         <agentRegex xsi:type="xsd:string">Custom Metric Host \(Virtual\)\|Custom Metric Process \(Virtual\)\|Custom Metric Agent \(Virtual\)</agentRegex>
         <metricPrefix xsi:type="xsd:string">Calculated Metrics\|CTG\|TTO\|Combined\|TTO Performance Analytics:TTO \- APP \- ActiveSessions \- SUM</metricPrefix>
      </met:getLiveMetricData>
   </soapenv:Body>
</soapenv:Envelope>
EOF
#url = "http://oprdttomo601.corp.intuit.net:8081/introscope-web-services/services/MetricsDataService?wsdl"
url = "http://oprdttomo601.corp.intuit.net:8081/introscope-web-services/services/MetricsDataService"
content = _generic_request("post", url, data, cfg, options)
puts content
exit

pp output

# Insert a row into QuickBase
message = "Updating QuickBase"
if (options[:dryrun])
	options[:logger].dryrun(message)
else
	options[:logger].info(message)
	qb.AddRecord({
		"fields" => output
	})
	pp qb.success ? qb.output : qb.errors
end
