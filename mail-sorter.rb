#!/usr/bin/ruby

# Docs
# https://github.com/WinRb/Viewpoint

require "etc"
require "kconv"
require "viewpoint"
require "highline/import"
require "pp"
require "getoptlong.rb"

module Viewpoint
	module EWS
		Logging.logger.root.level = :error
		Logging.logger.root.appenders = Logging.appenders.stdout
	end # EWS
end

include Viewpoint::EWS

# Command line options
$opt_h = nil
$opt_d = nil
$opt_n = nil
$opt_u = nil

def do_help
print <<EOF
Usage: mail-sorter [--help] [--debug] [--dryrun] [--username <string>]
Options:
 --help, -h
    Display this help text.
 --debug, -d
    Print useful debugging information.
 --dryrun, -n
    Print what would be done without actually doing anything.
 --username, -u
    Specify a username to login as. The default username is that of the invoking user.

Please submit any questions regarding this utility to gary_danko@intuit.com
EOF
exit
end

def debug_text(text)
	return unless $opt_d == 1
	puts ("[Debug] #{text}")
end

def dryrun_text(text)
	return unless $opt_n == 1
	puts ("[Dryrun] #{text}")
end

def error_exit(text)
	puts ("[Error] #{text}")
	exit
end

def info_text(text)
	puts ("[Info] #{text}")
end

# Defaults
endpoint = "https://outlook.intuit.com/EWS/Exchange.asmx"
$read = Array.new
$top_name = "Intuit Co-Workers"

opts = GetoptLong.new(
	[ "--help", "-h", GetoptLong::NO_ARGUMENT ],
	[ "--debug", "-d", GetoptLong::NO_ARGUMENT ],
	[ "--dryrun", "-n", GetoptLong::NO_ARGUMENT ],
	[ "--username", "-u", GetoptLong::REQUIRED_ARGUMENT ],
);

opts.each do |opt, arg|
	case opt
		when "--debug"
			$opt_d = 1
		when "--dryrun"
			$opt_n = 1
		when "--username"
			$opt_u = arg
		when "--help"
			do_help()
	end
end

error_exit("--debug and --dryrun cannot be used together.") if $opt_d && $opt_n

if $opt_u
	username = $opt_u
else
	username = Etc.getlogin
	username = ask("Username (#{username}): ") && Etc.getlogin
end
password = ask("Password (#{username}): ") {|q| q.echo = "*" }

cli = Viewpoint::EWSClient.new endpoint, username, password, { :server_version => "Exchange2010_SP1" }

top = cli.get_folder_by_name $top_name
inbox = cli.get_folder_by_name "Inbox"

def get_read_messages(inbox)
	inbox.items.each do |i|
		$read.push(i) if i.read? == true
	end
end

def folder_exists(cli, top, name)
	folder = cli.get_folder_by_name name , parent: top.id
	folder_name = "#{$top_name}/#{name}"
	if folder == nil
		message = "Folder \"#{folder_name}\" does not exist. Attempting to create."
	else
		message = "Folder \"#{folder_name}\" already exists."
	end
	return { "folder" => folder, "message" => message }
end

def make_folder(cli, top, name)
	folder_name = "#{$top_name}/#{name}"
	if $opt_n == 1
		dryrun_text ("Attempting to create folder \"#{folder_name}\".")
	else
		info_text ("Attempting to create folder \"#{folder_name}\".")
		begin
			folder = cli.make_folder name, parent: top.id
		rescue
			message = "Failed to create folder \"#{folder_name}\"."
		else
			message = "Successfully created folder \"#{folder_name}\"."
		end
		return { "folder" => folder, "message" => message }
	end
end

def move_message(cli, item, folder)
	folder_name = "#{$top_name}/#{folder.display_name}"
	if $opt_n == 1
		dryrun_text ("Moving message to \"#{folder_name}\".")
	else
		info_text ("Moving message to \"#{folder_name}\".")
		begin
			item.move! folder
		rescue
			message = "Failed to move the message to \"#{folder_name}\"."
		else
			message = "Successfully moved the message to \"#{folder_name}\"."
		end
		return { "message" => message }
	end
end

get_read_messages(inbox)

areyousure = ask("Are you sure you want to sort #{$read.length} messages? (y/N) ") || "n"
exit unless areyousure =~ /^[Yy]$/

$read.each do |item|
	if (item.from.name =~ /^[^,]+,\s*.*$/)
		if $opt_n == 1
			dryrun_text ("Moving message to \"#{$top_name}/#{item.from.name}\".")
		else
			data = folder_exists(cli, top, item.from.name)
			debug_text(data["message"])

			if data["folder"] == nil
				data = make_folder(cli, top, item.from.name)
				debug_text(data["message"])
			else
				data = move_message(cli, item, data["folder"])
			end
		end
	end
end

# i
# Viewpoint::EWS::Types::Message: EWS METHODS: associated?, attachments, body, body_type, categories, change_key, conversation_id, conversation_index, conversation_topic, date_time_created, date_time_sent, draft?, extended_properties, from, has_attachments?, id, importance, internet_message_headers, internet_message_id, is_associated?, is_draft?, is_read?, is_submitted?, read?, sender, sensitivity, size, subject, submitted?, to_recipients

# i.from
# Viewpoint::EWS::Types::MailboxUser: EWS METHODS: email, email_address, extended_properties, name

# folder
# Viewpoint::EWS::Types::Folder: EWS METHODS: change_key, child_folder_count, ckey, display_name, extended_properties, folder_class, id, name, parent_folder_change_key, parent_folder_id, total_count, unread_count

# move a message
# https://github.com/WinRb/Viewpoint/issues/125
# item.move! <folder_obj>
