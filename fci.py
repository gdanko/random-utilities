import sys
from time import sleep
import splunklib.results as results
import json
import splunklib.client as client
from influxdb import InfluxDBClient
import time
import os.path
import pprint
import yaml
import argparse
import logging
import re

# For debugging only
pp = pprint.PrettyPrinter(indent=4)

def configure_logger():
    logger = logging.getLogger()
    handler = logging.StreamHandler()
    formatter = logging.Formatter(
        "%(levelname)s %(message)s"
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    return logger

def join(loader, node):
    seq = loader.construct_sequence(node)
    return ''.join([str(i) for i in seq])

def load_config(cfg_file):
    if os.path.isfile(cfg_file):
        stream = file(cfg_file, "r")
        yaml.add_constructor('!join', join)
	try:
	    cfg = yaml.load(stream)
            return cfg
        #except yaml.composer.ComposerError as e:
        except yaml.YAMLError as e:
            s = re.sub(r"\n", " ", str(e))
            s = re.sub(r"\s+", " ", s)
            logger.critical("An error was found in the configuration file: %s" % (s))
            sys.exit(1)
    else:
        logger.critical("Configuration file " + cfg_file + " not found.")
        sys.exit(1)

def get_args(cfg_file):
    parser = argparse.ArgumentParser(
        description = "Load data from Splunk and insert it into InfluxDB."
    )
    parser.add_argument("-l", "--list", help="List all available configuration items from " + cfg_file + ".", action="store_true")
    parser.add_argument("-c", "--config", help="The configuration item to use from " + cfg_file + ".", type=str, required=False)
    args = parser.parse_args()
    return parser, args.list, args.config

logger = configure_logger()
cfg_file = "/root/.fci.yml"
cfg = load_config(cfg_file)
#pp.pprint(cfg)
#sys.exit()
parser, list_configs, config_name = get_args(cfg_file)
required_keys = 12

if list_configs == True:
    print "Available configuration items:"
    for x in cfg["configs"]:
        print "  " + x
    sys.exit()

if config_name:
    if cfg["configs"].has_key(config_name):
        cfg_obj = cfg["configs"][config_name]
        if len(cfg_obj.keys()) != required_keys:
            logger.critical("A configuration object should have %d keys, yours has %d. Please check your configuration file." % (required_keys, len(cfg_obj.keys())))
            sys.exit(1)
    else:
        logger.critical("Unknown configuration name. Use --list to see a list of configuration names.")
        sys.exit(1)
else:
    logger.critical("The required --config option is missing.")
    parser.print_help()
    sys.exit(1)

splunk_job_server = cfg_obj["splunk_job_server"]
splunk_user = cfg_obj["splunk_user"]
splunk_pass = cfg_obj["splunk_pass"]
splunk_summary_index = cfg_obj["splunk_summary_index"]
splunk_search_name = cfg_obj["splunk_search_name"]
influxdb_host = cfg_obj["influxdb_host"]
influxdb_user = cfg_obj["influxdb_user"]
influxdb_pass = cfg_obj["influxdb_pass"]
influxdb_db = cfg_obj["influxdb_db"]
tags = cfg_obj["tags"]
fields = cfg_obj["fields"]
searchquery_normal = cfg_obj["searchquery_normal"]

logger.info("Starting")

service = client.connect(host=splunk_job_server, port=8089, username=splunk_user,
                         password=splunk_pass, scheme='https')

kwargs_normalsearch = {"exec_mode": "normal"}
job = service.jobs.create(searchquery_normal, **kwargs_normalsearch)
pattern1 = '%Y-%m-%dT%H:%M:%S.%f-08:00'
pattern2 = '%Y-%m-%dT%H:%M:%S.%f-07:00'
# A normal search returns the job's SID right away, so we need to poll for completion
while True:
    while not job.is_ready():
        pass
    stats = {"isDone": job["isDone"],
             "doneProgress": float(job["doneProgress"])*100,
             "scanCount": int(job["scanCount"]),
             "eventCount": int(job["eventCount"]),
             "resultCount": int(job["resultCount"])}

    status = ("\r%(doneProgress)03.1f%%   %(scanCount)d scanned   "
              "%(eventCount)d matched   %(resultCount)d results") % stats

    sys.stdout.write(status)
    sys.stdout.flush()
    if stats["isDone"] == "1":
        sys.stdout.write("\n\nDone!\n\n")
        break
    sleep(2)

print "Search results:\n"
resultCount = job["resultCount"]  # Number of results this job returned
offset = 0;                       # Start at result 0
count = 100;                      # Get sets of 10 results at a time

influx_client_tpi = InfluxDBClient(influxdb_host, 8086, influxdb_user, influxdb_pass, influxdb_db)

while (offset < int(resultCount)):
    kwargs_paginate = {"count": count, "offset": offset}

    # Get the search results and display them
    json_array=[]
    blocksearch_results = job.results(**kwargs_paginate)
    logger.info("Processing Splunk Results")
    for result in results.ResultsReader(blocksearch_results):
        tags_dict = dict()
        for key in tags:
            tags_dict[key] = result[ tags[key] ]
        fields_dict = dict()
        for key in fields:
            fields_dict[key] = float(result[ fields[key] ])
	try:
		epoch = int(result['info_max_time'][:10])
		influx_measurement = splunk_search_name
		json_body = [
          	    {
                        "measurement": influx_measurement,
            	        "time": epoch,
                        "tags": tags_dict,
                        "fields": fields_dict
          	    }
        	]
		json_array.extend(json_body)
	except :
		pass
    influx_client_tpi.write_points(json_array)
    offset += count
    logger.info("%d of %d processed" % (int(offset),int(resultCount)))

logger.info("Completed Processing")

job.cancel()
sys.stdout.write('\n')
