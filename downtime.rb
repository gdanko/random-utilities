#!/usr/bin/ruby

require "/Users/gdanko/git/ruby-servicenow/lib/servicenow/simple.rb"
require "/Users/gdanko/git/ruby-servicenow/lib/servicenow/filter.rb"
#require "servicenow"
require "pp"
require "date"
require "time"
require "optparse"
require "yaml"
require "logger"

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

def start_end_times()
	end_time = Time.now
	d = Date.new(end_time.year, end_time.month, end_time.day)
	d <<= 1
	start_time = Time.local(d.year, d.month, d.day, end_time.hour, end_time.min, end_time.sec, end_time.usec)
	return {
		"start_time" => start_time,
		"end_time" => end_time
	}
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

options = Hash.new
options[:logger] = Logger.new(STDOUT)
options[:logger].formatter = proc do |severity, datetime, progname, msg|
	sprintf("[%s] %s\n", severity.capitalize, msg)
end

optparse = OptionParser.new do |opts|
	opts.separator "Fetch information about major incidents for a set of CIs over a period of time."
	opts.on("-h", "--help", "Display this help.") do
		puts opts
		exit 0
	end

	opts.on("--list-programs", "List all available programs.") do |arg|
		options[:list_programs] = arg
	end

	opts.on("--list-cis <programname>", "List all CIs for <programname>. Use program name all to list all available CIs") do |arg|
		options[:list_cis] = arg
	end

	opts.on("-d", "--debug", "Enable debug output for the ServiceNow gem.") do |arg|
		options[:sn_debug] = arg
	end

	opts.on("-c", "--ci <ci1,ci2,ci3>", "Comma-delimited list of Configuration Item names. You should quote this list.") do |arg|
		options[:ci] = arg
	end

	opts.on("-p", "--program <string>", "Select a program to use. Use --l to list program names.") do |arg|
		options[:program] = arg
	end

	opts.on("-s", "--start <yyyy-mm-dd>", "Start date in the format yyyy-mm-dd. Default: now - 1 month") do |arg|
		options[:start] = arg
	end

	opts.on("-e", "--end <yyyy-mm-dd>", "End date in the format yyyy-mm-dd. Default: now") do |arg|
		options[:end] = arg
	end

	opts.on("-o", "--orderby <field>", "Field to sort the results by, e.g. cmdb_ci or priority.") do |arg|
		options[:orderby] = arg
	end
end

if (ARGV.length == 0)
	puts optparse
	exit 1
end

begin
	optparse.parse!
rescue OptionParser::ParseError => error
	puts optparse
	exit 1
end

cfg_file = sprintf("%s/.downtime.yml", Dir.home)
cfg = load_config(options, cfg_file)
default_start_end = start_end_times()

# List available programs if they exist
if (options[:list_programs])
	if (cfg["programs"])
		cfg["programs"].keys.sort.each do |name|
			puts name
		end
		exit 0
	else
		logger.fatal("No programs defined in the configuration file.")
		exit 1
	end
end

# List available CIs for a given program
if (options[:list_cis])
	if (options[:list_cis] == "all")
		if (cfg["programs"])
			ci_arr = Array.new
			cfg["programs"].keys.each do |name|
				cfg["programs"][name].each do |ci|
					ci_arr.push(ci)
				end
			end
		end
		ci_arr.sort.each do |name|
			puts name
		end
		exit 0
	else
		if (cfg["programs"][options[:list_cis]])
			cfg["programs"][options[:list_cis]].sort.each do |name|
				puts name
			end
			exit 0
		else
			logger.fatal(sprintf("Unknown program name: %s", options[:list_cis]))
			exit 1
		end
	end
end

ci_list = nil

sn = ServiceNow::Simple.new({
	"env" => cfg["servicenow"]["env"],
	"username" => cfg["servicenow"]["username"],
	"password" => cfg["servicenow"]["password"],
	"proxy" => "http://qypprdproxy02.ie.intuit.net:80"
})
sn.debug("on") if options[:sn_debug]

# Option validation
if (options[:ci] && options[:program])
	puts "ci and program options are mutually exclusive."
	exit 1
end

if (!options[:ci] && !options[:program])
	puts "Please use either the ci or program options."
	exit
end

if (options[:ci])
	ci_list = options[:ci]
elsif (options[:program])
	if (cfg["programs"].key?(options[:program]))
		ci_list = cfg["programs"][options[:program]].join(",")
	else
		puts "Program #{options[:program]} does not exist."
		exit 1
	end
end

if (options[:start])
	unless(options[:start] =~ /^\d\d\d\d-\d\d-\d\d$/)
		puts "Invalid start date."
		puts optparse
		exit 1
	end
else
	options[:start] = default_start_end["start_time"].strftime("%Y-%m-%d")
	#puts "Missing start time option."
	#puts optparse
	#exit 1
end

if (options[:end])
	unless(options[:end] =~ /^\d\d\d\d-\d\d-\d\d$/)
		puts "Invalid end date."
		puts optparse
		exit 1
	end
else
	options[:end] = default_start_end["end_time"].strftime("%Y-%m-%d")
	#puts "Missing end time option."
	#puts optparse
	#exit 1
end

if (Time.parse(options[:start]).to_i > Time.parse(options[:end]).to_i)
	puts "Start time cannot be greater than end time."
	exit 1
end

# Logic
# Old
#filter = ServiceNow::Filter.new
##filter.add("u_major_incident", "=", "true")
#filter.add("cmdb_ci.name", "IN", ci_list)
#filter.add("u_start_date", ">=", options[:start])
#filter.add("u_start_date", "<=", options[:end])
#filter.add("priority", "<=", "high")
#sn.orderby(options[:orderby]) if options[:orderby]
#sn.filters(filter)
#sn.major_incident_find

# New
filter = ServiceNow::Filter.new
filter.add("cmdb_ci.name", "IN", ci_list)
filter.add("u_start_date", ">=", options[:start])
filter.add("u_start_date", "<=", options[:end])
filter.add("priority", "IN", "1,2")
sn.orderby(options[:orderby]) if options[:orderby]
sn.filters(filter)
sn.incident_find

ci_arr = ci_list.split(/\s*,\s*/)
incident_ids = Array.new
incidents = Hash.new
sprintf = "%-12s%-35s%-20s%-25s%-20s%-12s%-20s%-50s"
header = sprintf(sprintf, "Number", "Configuration Item", "Priority", "Opened At", "Duration", "Impact %", "Downtime", "Description")
divider = "=" * (header.length + 4)

# Incidents is a hash with inc# as key
# Put incident #s into an array and make one call to SN for outage info

if (sn.success)
	sn.output.each do |i|
		incident_ids.push(i["number"])
		duration = "unknown"
		resolved = fix_snow_time(i["u_repair_date"])
		opened = fix_snow_time(i["u_start_date"])
		if (resolved && opened)
			duration = sprintf("%s min", ((resolved - opened) / 60).to_i)
		end

		opened_at = Time.at( fix_snow_time(i["opened_at"]) ).to_datetime
		hash = {
			:number => i["number"],
			:cmdb_ci => i["cmdb_ci"],
			:priority => i["priority"].split(/\s+-\s+/)[1],
			:opened_at => opened_at.strftime("%Y-%m-%d %H:%M:%S"),
			:duration => duration,
			:pct_impact => 0,
			:downtime => 0,
			:desc => i["short_description"][0..50]
		}
		incidents[i["number"]] = hash
	end

	# Get all the outages
	filter.clear
	filter.add("task_number.number", "IN", incident_ids.join(","))
	filter.add("u_outage_severity", "IN", "1,2")
	sn.filters(filter)
	sn.outage_find
	if (sn.success)
pp sn.output;exit
		sn.output.each do |o|
			if (incidents.key?(o["task_number"]))
				if (o["cmdb_ci"] == incidents[o["task_number"]][:cmdb_ci])
					incidents[o["task_number"]][:pct_impact] = incidents[o["task_number"]][:pct_impact] + o["u_percent_of_impact"].to_i
				end
			end	
		end
	else
		puts "Failed to get outage info."
		exit 1
	end

	puts header
	puts divider
	incidents.each_key do |inc_number|
		i = incidents[inc_number]
		d = i[:downtime] = i[:duration].split[0] 
		p = i[:pct_impact] / 100.to_f
		i[:downtime] = (d.to_f * p.to_f).to_i
		puts sprintf(
			sprintf,
			i[:number],
			i[:cmdb_ci],
			i[:priority],
			i[:opened_at],
			i[:duration],
			i[:pct_impact],
			sprintf("%s min", i[:downtime]),
			i[:desc]
		)
	end
else
	pp sn.errors
end
