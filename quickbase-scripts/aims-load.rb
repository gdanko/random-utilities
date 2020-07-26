#!/usr/bin/env ruby

require "pp"
require "json"
require "/Users/gdanko/git/ruby-servicenow/lib/servicenow/simple.rb"
require "/Users/gdanko/git/ruby-servicenow/lib/servicenow/filter.rb"
require "optparse"
require "logger"
require "time"
require "date"
require "tzinfo"

env, username, password = "dev1", "json.soap", "intuit"

sn = ServiceNow::Simple.new({
	"env" => env,
	"username" => username,
	"password" => password,
	#"proxy" => "http://qypprdproxy02.ie.intuit.net:80"
})
sn.debug("off")

def create(sn, logger, hash, rid)
	sn.incident_create(hash)
	if (sn.success)
		logger.info(sprintf("Successfully created %s", sn.output[0]["number"]))
	else
		logger.error(sprintf("Failed to create an incident for RID %s: %s", rid, sn.errors))
	end
end

contents = File.read("aims-data.json")
aims_data = JSON.parse(contents)

domain_map = {
	"FDS" => "Financial Data Services (FDS)",
	"CTO-Mobile" => "Mobile",
	"CTO-Public Cloud" => "Public Cloud",
	"CTO-Tools" => "Tools",
	"ICS" => "ICS"
}

datacenter_map = {
	"AWS" => "AWS Other",
	"QDC" => "QDC-A",
	"LVDC" => "LVDC-A",
	"MTV" => "MTV"
}

planned_map = {
	"N" => "No",
	"Y" => "Yes"
}

detected_by_map = {
	"AppOps" => "Employee",
	"Customer" => "Customer",
	"Monitoring" => "Monitoring",
	"Splunk" => "Monitoring",
	"application alerts" => "Monitoring"
}

# No root cause map needed

# No category map needed

# trigger_service > cmdb_ci
ci_map = {
	"FDS FDS Aggregation" => "FDS Aggregation",
	"FDS FDS Aggregation (CAD)" => "FDS Aggregation (CAD)",
	"FDS FDS Branding" => "FDS Branding",
	"FDS FDS Document Service" => "FDS Document Service",
	"FICDS Aggregation" => "UNKNOWN",
	"SharedServ API Gateway" => "API Gateway",
	"SharedServ IUS" => "Identity Universal Service (IUS)",
	"SharedServ IUX" => "Identity User eXperience (IUX)",
	"SharedServ LBS" => "Location Based Services (LBS)",
	"SharedServ Risk Screening Service (RSS)" => "Risk Screening Service (RSS)",
	"SharedServ Tool JIRA" => "CTODev Jira",
	"SharedServ Tool VDL" => "UNKNOWN"
}

# No enterprise impact map needed

logger = Logger.new(STDOUT)
logger.formatter = proc do |severity, datetime, progname, msg|
	sprintf("[%s] %s\n", severity.capitalize, msg)
end

options = {}

optparse = OptionParser.new do |opts|
	opts.separator "Load data from AIMS into ServiceNow"
	opts.on("-h", "--help", "Display this help.") do
		puts opts
		exit 0
	end

	opts.on("-n", "--drydrun", "Dryrun") do
		options[:dryrun] = arg
	end
end

begin
	optparse.parse!
rescue OptionParser::ParseError => error
	logger.fatal(error)
	exit 1
end

def to_snow_time(event_date, event_time)
	# "9:10am"
	hour, minute, ampm = 0, 0, "am"
	if (event_time =~ /^([0-9]+):([0-9]+)(.*)$/)
		hour, minute, ampm = $1, $2, $3
	end
	output_time = sprintf("%s:%s:00 %s",
		sprintf("%02d", $1),
		sprintf("%02d", $2),
		$3.upcase
	)

	output_date_object = DateTime.strptime(event_date.to_s, "%s")
	output_date = sprintf("%s-%s-%s",
		output_date_object.year,
		sprintf("%02d", output_date_object.month),
		sprintf("%02d", output_date_object.day)
	)
	#unix_time = Time.parse( sprintf("%s %s", output_date, output_time) ).to_i + TZInfo::Timezone.get(tz).current_period.offset.utc_total_offset.abs

	unix_time = Time.parse( sprintf("%s %s", output_date, output_time) ).to_i
	d = DateTime.strptime(unix_time.to_s, "%s")
	return d.strftime("%m-%d-%Y %H:%M:%S")
end

aims_data.each do |item|
	logger.warn(sprintf("No CI found for QuickBase trigger service %s. I will still create the incident but the Configuration Item field will be blank.", item["trigger_service"])) if ci_map[item["trigger_service"]] == "UNKNOWN"
	comment = ""
	comment += sprintf("AIMS RID: %s\n", item["@rid"])
	comment += sprintf("AIMS URL: https://intuitcorp.quickbase.com/db/54xa5xi4?a=dr&rid=%s&rl=k4x\n", item["@rid"])  
	comment += sprintf("Domain: %s\n", domain_map[item["domain"]])
	comment += sprintf("Datacenter: %s\n", item["datacenter"])
	comment += sprintf("Planned: %s\n", planned_map[item["planned"]])
	comment += sprintf("Root Cause: %s\n", item["root_cause_status"])
	comment += sprintf("Category: %s\n", item["category"])
	comment += sprintf("Outage: %s\n", item["outage_type"])
	comment += sprintf("Severity: %s\n", item["severity"])
	comment += sprintf("Enterprise Impact: %s\n", item["enterprise_impact"])
	comment += sprintf("Environment: %s\n", item["environment"])
	comment += sprintf("No. Cust/Txns Impacted: %s\n", item["no__cust_txns_impacted"])
	comment += sprintf("%% Txns Impacted: %s\n", item["__txns_impacted"])
	comment += "\n"

	opened_at = to_snow_time((item["event_date"].to_i / 1000), item["event_time"])

	hash = {
		"u_client" => "gdanko",
		"short_description" => item["short_desc"],
		"u_detected_by" => detected_by_map[item["detected_by"]],
		"comments" => comment,
		"cmdb_ci" => ci_map[item["trigger_service"]],
		"caller_id" => "gdanko",
		"opened_by" => "gdanko",
		"location" => "San Diego (SDG)",
		"opened_at" => opened_at
	}
	create(sn, logger, hash, item["@rid"])
end
