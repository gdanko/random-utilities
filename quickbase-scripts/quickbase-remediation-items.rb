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
	filter.add("u_start_date", ">=", options[:start_date])
	filter.add("u_start_date", "<=", foo)
	sn.filters(filter)
	sn.incident_find
	
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
				"number" => i["number"],
				"program" => services[i["cmdb_ci"]],
				"cmdb_ci" => i["cmdb_ci"],
				"priority" => i["priority"].split(/\s+-\s+/)[1],
				"opened_at" => opened_at.strftime("%Y-%m-%d %T"),
				"desc" => i["short_description"].chomp,
				"tasks" => Hash.new
			}
			incidents[i["number"]] = hash
		end
	
		filter.clear
		filter.add("u_ud_parent.number", "in", incident_ids.join(","))
		sn.filters(filter)
		sn.incident_task_find
		if (sn.success)
			sn.output.each do |t|
				if (incident_ids.include?(t["u_ud_parent"]))
					i_num = t["u_ud_parent"]
					t_num = t["number"]
					hash = {
						"number" => t["number"],
						"priority" => t["priority"],
						"parent" => t["u_ud_parent"],
						"due_date" => t["due_date"],
						"reassignment_count" => t["reassignment_count"],
						"state" => t["state"],
						"assigned_to" => t["assigned_to"]
					}
					incidents[i_num]["tasks"][t_num] = hash
				end
				incidents[i_num]["remediation_items"] = incidents[i_num]["tasks"].keys.length
			end
		end
	end

	return incidents
end

# Set variables
options = {:start_date => "2014-01-01"}
options[:logger] = Logger.new(STDOUT)
options[:logger].formatter = proc do |severity, datetime, progname, msg|
	sprintf("[%s] %s\n", severity.capitalize, msg)
end

dbname = sprintf("%s/snow-reports.db", Dir.home)

optparse = OptionParser.new do |opts|
	opts.separator "Query ServiceNow for incident data and find remediation items."
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

cfg_file = sprintf("%s/.downtime.yml", Dir.home)
cfg_name = "remediation"
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
	#"proxy" => cfg_obj["http_proxy"]["host"]
})
sn.debug("on")

qb_incidents = QuickBase.new({
	"env" => "prod",
	"username" => qb_user,
	"password" => qb_pass,
	"token" => cfg_obj["quickbase"]["token"],
	"debug" => "on",
	"db" => "bkqaqczmy"
})

qb_tasks = QuickBase.new({
	"env" => "prod",
	"username" => qb_user,
	"password" => qb_pass,
	"token" => cfg_obj["quickbase"]["token"],
	"debug" => "on",
	"db" => "bkqaqxte2"
})

incidents = gather_snow_data(options, sn, services)

# purge the table
qb.PurgeRecords({
	"qid" => 5
})
pp qb.success ? qb.output : qb.errors

# purge the table
qb.PurgeRecords({
	"qid" => 9
})
pp qb.success ? qb.output : qb.errors
exit

exit

total = incidents.keys.length
counter = 0
incidents.each do |k,i|
	incidents_fields = {
		"Number" => i["number"],
		"Priority" => i["priority"],
		"Service" => i["cmdb_ci"],
		"Program" => i["program"],
		"Opened" => i["opened_at"],
		"Remediation Count" => i["remediation_items"],
		"Description" => i["desc"],
	}
	counter = counter + 1
	message = "Attempting to insert incident record #{counter} of #{total}"

	if (options[:dryrun])
		options[:logger].dryrun(message)
	else
		options[:logger].info(message)
		qb_incidents.AddRecord({
			"fields" => incidents_fields
		})
		options[:logger].warn(qb_incidents.errors) unless qb_incidents.success
	end

	if (i["tasks"] && i["tasks"].keys.length > 0)
		ttotal = i["tasks"].keys.length
		tcounter = 0
		i["tasks"].each do |k,t|
			tasks_fields = {
				"Number" => t["number"],
				"Parent Incident" => t["parent"],
				"Priority" => t["priority"],
				"Due Date" => t["due_date"],
				"Reassignment Count" => t["reassignment_count"],
				"State" => t["state"],
				"Owner" => t["assigned_to"]
			}

			tcounter = tcounter + 1
			message = "Attempting to insert task record #{tcounter} for #{ttotal} for incident #{counter}"
			if (options[:dryrun])
				options[:logger].dryrun(message)
			else
				options[:logger].info(message)
				qb_tasks.AddRecord({
					"fields" => tasks_fields
				})
				options[:logger].warn(qb_tasks.errors) unless qb_tasks.success
			end
		end
	end
end
