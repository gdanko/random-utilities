#!/usr/bin/env ruby
require "pp"
require "json"
require "logger"
require "yaml"
require "optparse"
require "servicenow"
require "influxdb"
require "time"
require "date"

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

def duration(seconds)
	seconds = seconds.to_i
	days = (seconds / 86400).to_i
	hours = ((seconds - (days * 86400)) / 3600).to_i
	mins = ((seconds - days * 86400 - hours * 3600) / 60).to_i
	sec = (seconds - (days * 86400) - (hours * 3600) - (mins * 60)).to_i
	output = Array.new
	output.push(sprintf("%dd", days)) if days > 0
	output.push(sprintf("%dh", hours)) if hours > 0
	output.push(sprintf("%dm", mins)) if mins > 0
	output.push(sprintf("%ds", sec)) if sec > 0
	return output.join(" ")
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
	options[:logger].info("Gathering incident data...")
	filter = ServiceNow::Filter.new
	filter.add("cmdb_ci.name", "IN", services.keys.join(","))
	filter.add("u_start_date", ">=", "2014-01-01")
	filter.add("u_start_date", "<=", foo)
	sn.filters(filter)
	sn.incident_find
	
	if (sn.success)
		options[:logger].info("Gathering outage data...")
		sn.output.each do |i|
			incident_ids.push(i["number"])
			duration = "unknown"
			resolved = fix_snow_time(i["u_repair_date"])
			opened = fix_snow_time(i["u_start_date"])
			if (resolved && opened)
				duration = sprintf("%d", ((resolved - opened) / 60).to_i)
			end
	
			opened_at = Time.at( fix_snow_time(i["opened_at"]) ).to_datetime
			foo = Time.parse(opened_at.strftime("%Y-%m-%d %H:%M:%S")).to_i
			foo = foo * 1000
	
			hash = {
				"number" => i["number"].chomp,
				"program" => services[i["cmdb_ci"]].chomp,
				"cmdb_ci" => i["cmdb_ci"].chomp,
				"priority" => i["priority"].split(/\s+-\s+/)[1].chomp,
				#opened_at" => Time.parse(opened_at.strftime("%Y-%m-%d %H:%M:%S")).to_i,
				"opened_at" => foo.to_i,
				"outage_duration" => duration.to_i,
				"pct_impact" => 0,
				"downtime" => 0,
				#"desc" => i["short_description"][0..50].chomp
				"desc" => i["short_description"].chomp
			}
			incidents[i["number"]] = hash
		end
	
		filter.clear
		filter.add("task_number.number", "IN", incident_ids.join(","))
		sn.filters(filter)
		sn.outage_find
		if (sn.success)
			sn.output.each do |o|
				if (incidents.key?(o["task_number"]))
					if (o["cmdb_ci"] == incidents[o["task_number"]]["cmdb_ci"])
						incidents[o["task_number"]]["pct_impact"] = incidents[o["task_number"]]["pct_impact"] + o["u_percent_of_impact"].to_i
					end
				end
			end
		end
	
		incidents.each_key do |inc_number|
			i = incidents[inc_number]
			d = i["outage_duration"]
			p = i["pct_impact"] / 100.to_f
			i["downtime"] = (d.to_f * p.to_f).to_i
		end
	end

	return incidents
end

# Set variables
options = Hash.new
options[:logger] = Logger.new(STDOUT)
options[:logger].formatter = proc do |severity, datetime, progname, msg|
	sprintf("[%s] %s\n", severity.capitalize, msg)
end

optparse = OptionParser.new do |opts|
	opts.separator "Query data from ServiceNow and import it into influx"
	opts.on("-h", "--help", "Display this help.") do
		puts opts
		exit 0
	end

	opts.on("-n", "--dryrun", "Do not update influx.") do |arg|
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

cfg_file = sprintf("%s/.snow-reports.yml", Dir.home)
cfg = load_config(options, cfg_file)
cfg_name = "downtime_report_1d"
cfg_obj = cfg["configs"][cfg_name]
services = get_all_services(cfg["programs"])

sn = ServiceNow::Simple.new({
    "env" => cfg_obj["servicenow"]["env"],
    "username" => cfg_obj["servicenow"]["user"],
    "password" => cfg_obj["servicenow"]["pass"],
    #"proxy" => cfg["http_proxy"]["host"] 
})
sn.debug("on")

influx = InfluxDB::Client.new(
	host: cfg_obj["influxdb"]["host"],
	database: cfg_obj["influxdb"]["db"],
	username: cfg_obj["influxdb"]["user"],
	password: cfg_obj["influxdb"]["pass"]
)

influx.delete_database(cfg_obj["influxdb"]["db"])
influx.create_database(cfg_obj["influxdb"]["db"])
#exit

#foo = influx.query("select * from #{cfg_name}") # where priority = 'Low'")
foo = influx.query("drop series from #{cfg_name}")
#pp foo.first["values"].length;exit
#pp foo; exit

incidents = gather_snow_data(options, sn, services)

# try to insert?
json_data = Array.new
counter = 0
incidents.each_key do |inc_number|
	counter = counter + 1
	fields = Hash.new
	tags = Hash.new
	i = incidents[inc_number]

	if (cfg_obj["fields"] && cfg_obj["fields"].keys.length > 0)
		cfg_obj["fields"].each do |k,v|
			if (i[v].is_a?(String))
				fields[k] = i[v].chomp
			else
				fields[k] = i[v]
			end
		end
	end

	if (cfg_obj["tags"] && cfg_obj["tags"].keys.length > 0)
		cfg_obj["tags"].each do |k,v|
			if (i[v].is_a?(String))
				tags[k] = i[v].chomp
			else
				tags[k] = i[v]
			end
		end
	end

	data = {
		:measurement => cfg_name,
		:timestamp => (fields[:opened_at]) / 1000.to_i,
		:tags => tags,
		:values => fields
	}
	pp data
	#options[:logger].info("Writing record #{counter}.")
	influx.write_point(cfg_name, data)
end
#pp incidents
