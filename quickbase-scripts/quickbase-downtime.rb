#!/usr/bin/env ruby

require "pp"
require "servicenow"
require "quickbase"
require "json"
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

def config_logger(log)
	logger = log ? Logger.new(log, 10, 1024000) : Logger.new(STDOUT)
	logger.datetime_format = "%Y-%m-%d %H:%M:%S"
	if (log)
		logger = Logger.new(log, 5, 1024000)
		logger.datetime_format = "%Y-%m-%d %H:%M:%S"
		logger.formatter = proc do |severity, datetime, progname, msg|
			sprintf("[%s] %-10s: %s\n", datetime, severity.downcase, msg)
		end
	else
		logger.formatter = proc do |severity, datetime, progname, msg|
			sprintf("[%s] %s\n", severity.capitalize, msg)
		end
	end
	return logger
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

def get_all_services(programs)
	services = Hash.new
	programs.each_key do |program_name|
		programs[program_name].each do |service_name|
			services[service_name] = program_name
		end
	end
	return services
end

def fix_snow_time(str)
	oy, om, od, time = nil, nil, nil, nil, nil, nil
	if (str =~ /(\d\d)-(\d\d)-(\d\d\d\d) (\d\d:\d\d:\d\d (AM|PM))/)
		om, od, oy, time = $1, $2, $3, $4
		return Time.parse(sprintf("%s-%s-%s %s", oy, om, od, time)).to_i
	end
	return nil
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

def get_timeframe_stats(timeframe)
	downtime = 0
	pct_impact = 0
	downtime = 0
	outage_duration = 0
	from, to = nil, nil
	outage_count = 0
	timeframe.each do |outage|
		outage_count += 1
		from = outage["detect_date"]
		to = outage["repair_date"]
		outage_duration = (outage["unix_repair_date"] - outage["unix_detect_date"]) / 60
		pct_impact = outage["impact_pct"] if outage["impact_pct"] > pct_impact
	end
	downtime = sprintf("%0.3f", (outage_duration.to_f * pct_impact.to_f) / 100)
	#puts sprintf("Range %s - %s", from, to)
	#puts sprintf("Duration: %s minutes", duration)
	#puts sprintf("Outages: %s: ", outage_count)
	#puts sprintf("Max impact: %s%%", pct_impact)
	#puts sprintf("Timeframe duration: %f minutes", downtime)
	#puts ""
	return {"downtime" => downtime.to_f, "outage_duration" => outage_duration, "pct_impact" => pct_impact}
end

def gather_snow_data(options, sn, services)
	now = Time.new
	foo = sprintf(
		"%04d-%02d-%02d",
		now.year,
		now.month,
		now.day
	)

	incident_ids = Array.new
	incidents = Hash.new
	options[:logger].add options[:log_type], "Gathering incident data..."
	filter = ServiceNow::Filter.new
	filter.add("cmdb_ci.name", "IN", services.keys.join(","))
	filter.add("u_start_date", ">=", options[:start_date])
	filter.add("u_start_date", "<=", foo)
	#filter.add("number", "=", "INC0346636")
	sn.filters(filter)
	sn.incident_find

	if (sn.success)
		options[:logger].add options[:log_type], "Gathering outage data..."
		sn.output.each do |i|
			incident_ids.push(i["number"])
			duration = "unknown"
			resolved = fix_snow_time(i["u_repair_date"])
			opened = fix_snow_time(i["u_start_date"])
			if (resolved && opened)
				duration = sprintf("%d", ((resolved - opened) / 60).to_i)
			end

			opened_at = Time.at( fix_snow_time(i["opened_at"]) ).to_datetime

			hash = {
				"number" => i["number"].chomp,
				"program" => services[i["cmdb_ci"]].chomp,
				"cmdb_ci" => i["cmdb_ci"].chomp,
				"priority" => i["priority"].split(/\s+-\s+/)[1].chomp,
				"opened_at" => opened_at.strftime("%Y-%m-%d %T"),
				"outage_duration" => duration.to_i,
				"pct_impact" => 0,
				"downtime" => 0,
				"desc" => i["short_description"].chomp,
				"outages" => Array.new
			}
			incidents[i["number"]] = hash
		end

		filter.clear
		filter.add("task_number.number", "IN", incident_ids.join(","))
		sn.filters(filter)
		sn.outage_find
		if (sn.success)
			sn.output.each do |o|
				outage_id = o["u_number"]
				parent_id = o["task_number"]
				if (incidents.key?(parent_id))
					incidents[parent_id]["outages"].push({
						"number" => outage_id,
						"parent" => parent_id,
						"cmdb_ci" => o["cmdb_ci"],
						"detect_date" => o["u_detect_date"],
						"repair_date" => o["u_restore_date"],
						"unix_detect_date" => fix_snow_time(o["u_detect_date"]),
						"unix_repair_date" => fix_snow_time(o["u_restore_date"]),
						"impact_pct" => o["u_percent_of_impact"].to_i
					})
				end
			end
		end
	end
	return incidents
end

# Set variables
options = {:start_date => "2014-01-01", :log => "stdout", :log_type => 1, :log_path => "/var/log/quickbase-downtime.log"}
options[:logger] = Logger.new(STDOUT)
options[:logger].formatter = proc do |severity, datetime, progname, msg|
	sprintf("[%s] %s\n", severity.capitalize, msg)
end

optparse = OptionParser.new do |opts|
	opts.separator "Query ServiceNow for incident data and calculate service downtime."
	opts.on("-h", "--help", "Display this help.") do
		puts opts
		exit 0
	end

	opts.on("-l", "--log <file|stdout>", "Log to either a file or STDOUT. Default is stdout. Log file location is #{options[:log_path]}.") do |arg|
		options[:log] = arg
	end

	opts.on("-n", "--dryrun", "Do not update QuickBase.") do |arg|
		options[:dryrun] = arg
		options[:log_type] = 6
	end
end

#if (ARGV.length == 0)
#	puts optparse
#	exit 1
#end

begin
	optparse.parse!
	options[:logger] = config_logger(nil)
rescue OptionParser::ParseError => error
	config_logger(nil).fatal(error)
	puts optparse
	config_logger(options[:log_path]).fatal(error)
	exit 1
end

# Validate --log
if (options[:log])
	if (options[:log] == "file")
		options[:logger] = config_logger(options[:log_path])
	elsif (options[:log] == "stdout")
		options[:logger] = config_logger(nil)
	else
		options[:logger] = config_logger(nil)
		logger.add Logger::WARN, sprintf("\"%s\" is not a valid argument for --log. Valid arguments are \"file\" and \"stdout\". Logging to STDOUT.", options[:log])
	end
end

cfg_file = sprintf("%s/.downtime.yml", Dir.home)
cfg_name = "downtime"
cfg = load_config(options, cfg_file)
cfg_obj = cfg["configs"][cfg_name]
qb_user, qb_pass = nil
services = get_all_services(cfg["programs"])

if (cfg_obj["quickbase"]["username"] && cfg_obj["quickbase"]["password"])
	qb_user, qb_pass = cfg_obj["quickbase"]["username"], cfg_obj["quickbase"]["password"]
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

sn = ServiceNow::Simple.new({
	"env" => cfg_obj["servicenow"]["env"],
	"username" => cfg_obj["servicenow"]["username"],
	"password" => cfg_obj["servicenow"]["password"],
	"proxy" => cfg["proxy"]
})
sn.debug("off")

qb = QuickBase.new({
	"env" => "prod",
	"username" => qb_user,
	"password" => qb_pass,
	"token" => cfg_obj["quickbase"]["token"],
	"debug" => "on",
	"db" => cfg_obj["quickbase"]["db"],
	"proxy" => cfg["proxy"]
})

options[:logger].add options[:log_type], "Purging the incidents table."
	unless (options[:dryrun])
	qb.PurgeRecords({
		"qid" => 6
	})
	unless (qb.success)
		logger.fatal(sprintf("Something bad has happened while purging the incidents table, cannot continue. %s", qb.errors))
		exit 1
	end
end

incidents = gather_snow_data(options, sn, services)
output_incidents = Hash.new

incidents.each_key do |k|
	incident = incidents[k]
	total_incident_time = 0
	incident_timeframes = Hash.new

	incident["outages"].each do |outage|
		range = sprintf("%s-%s", outage["unix_detect_date"], outage["unix_repair_date"])
		if (incident_timeframes.has_key?(range))
			incident_timeframes[range].push(outage)
		else
			incident_timeframes[range] = Array.new
			incident_timeframes[range].push(outage)
		end
	end

	# downtime = calculate downtime for period
	# duration = period duration
	# impact % = period impact %
	counter = 0
	incident_timeframes.each_key do |t|
		timeframe = incident_timeframes[t]

		adjusted_number = sprintf("%s-%s", incident["number"], counter)
		output_incidents[adjusted_number] = incidents[k].clone
		output_incidents[adjusted_number]["number"] = adjusted_number
		output_incidents[adjusted_number].delete("outages")

		timeframe_stats = get_timeframe_stats(timeframe)
		timeframe_stats.each do |k, v|
			output_incidents[adjusted_number][k] = v
		end
		counter = counter + 1
	end
end

total = output_incidents.keys.length
counter = 0
output_incidents.each do |k,i|
	fields = {
		"Number" => i["number"],
		"Priority" => i["priority"],
		"Program" => i["program"],
		"Service" => i["cmdb_ci"],
		"Downtime (min)" => i["downtime"],
		"Duration (min)" => i["outage_duration"],
		"Impact %" => i["pct_impact"],
		"Opened" => i["opened_at"],
		"Description" => i["desc"]
	}
	counter = counter + 1
	message = "Attempting to insert record #{counter} of #{total}"

	if (options[:dryrun])
		options[:logger].add options[:log_type], message
	else
		options[:logger].add options[:log_type], message
		qb.AddRecord({
			"fields" => fields
		})
		options[:logger].warn(qb.errors) unless qb.success
	end
end
