#!/usr/bin/env ruby

require "net/imap"
require "pp"
require "etc"
require "kconv"
require "logger"
require "optparse"
require "uri"

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
	printf("Username (#{Etc.getlogin}): ")
	username = STDIN.gets.chomp
	username = username.length > 1 ? username : Etc.getlogin

	printf("Password for #{username}: ")
	system "stty -echo"
	password = STDIN.gets.chomp
	system "stty echo"
	puts ""
	return {
		"username" => sprintf("%s@corp.intuit.net", username) || nil,
		"password" => password || nil
	}
end

def user_auth()
	output = {"username" => nil, "password" => nil}
	username = Etc.getlogin
	if (username)
		output["username"] = sprintf("%s@corp.intuit.net", username) || nil
		filename = sprintf("%s/.%s", Dir.home, username)
		if (File.exist?(filename))
			output["password"] = URI.encode(File.read(filename).chomp).gsub(/&/, "%26")
		end
	end
	return output
end

def check_folder(logger, imap, name)
	folder = sprintf("%s/%s", $coworker_prefix, name)
	if (imap.list(folder, "*"))
		return 1
	else
		return nil
	end
end

def move_message(logger, imap, id, name)
	dest = sprintf("%s/%s", $coworker_prefix, name)
	msg_text = "Filing message ID #{id} to \"#{dest}\""
	if ($dryrun == 1)
		logger.dryrun(msg_text)
	else
		begin
			logger.info(msg_text)
			imap.copy(id, dest)
			imap.store(id, "+FLAGS", [:Deleted])
		rescue
			logger.warn("Failed to file message ID #{id} to \"#{dest}\"")
		end
	end
end

def make_folder(logger, imap, name)
	folder = sprintf("%s/%s", $coworker_prefix, name)
	msg_text = "Creating folder \"#{folder}\""
	if ($dryrun == 1)
		logger.dryrun(msg_text)
	else
		logger.info(msg_text)
		begin
			imap.create(folder)
		rescue
			logger.warn("Failed to create the folder \"#{folder}\"")
		end
	end
end

server = "outlook.office365.com"
port = "993"
creds = Hash.new
options = Hash.new
$coworker_prefix = "Intuit Co-Workers"
$dryrun = 0

logger = Logger.new(STDOUT)
logger.formatter = proc do |severity, datetime, progname, msg|
	sprintf("[%s] %s\n", severity.capitalize, msg)
end

optparse = OptionParser.new do |opts|
	opts.separator "Sort my email."
	opts.on("-h", "--help", "Display this help.") do
		puts opts
		exit 0
	end

	if (Etc.getlogin == "gdanko")
		opts.on("--gd", "Attempt to login with GD's credentials.") do |arg|
			options[:user_auth] = arg
		end
	end
end

begin
    optparse.parse!
rescue OptionParser::ParseError => error
    logger.fatal(error)
    exit 1
end

if (options[:user_auth] == true)
	creds = user_auth()
	unless (creds["username"] && creds["password"])
		creds = auth()
	end
else
	creds = auth()
end

imap = Net::IMAP.new(server, port, true)
begin
	imap.login(creds["username"], creds["password"])
rescue
	logger.fatal("Login failed. :(")
	exit 1
end

imap.select("INBOX")
imap.search(["SEEN"]).each do |id|
	envelope = imap.fetch(id, "ENVELOPE")[0].attr["ENVELOPE"]
	if (defined?"#{envelope.from[0].name}")
		name = "#{envelope.from[0].name}"
	else
		name = "NO NAME"
	end
	from = { "name" => name.chomp, "mailbox" => "#{envelope.from[0].mailbox}".chomp, "host" => "#{envelope.from[0].host}".chomp }

	if (from["mailbox"] =~ /^[^_]+_[^_]+$/ && from["host"] =~ /[\.]*intuit.com$/)
		make_folder(logger, imap, name) unless check_folder(logger, imap, from["name"])
		move_message(logger, imap, id, from["name"])
	else
		logger.warn(sprintf("Not filing message ID %s from %s@%s", id, from["mailbox"], from["host"]))
	end
end

logger.info("Expunging...")
imap.expunge
logger.info("Disconnecting...")
imap.logout
imap.disconnect
logger.info("Done!")
