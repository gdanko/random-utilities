#!/usr/bin/env ruby

require "pp"
require "nokogiri"
require "mechanize"
require "logger"

output = Hash.new
counter = 0
agent = Mechanize.new
agent.log = Logger.new "mech.log"
agent.user_agent_alias = "Mac Safari"

def auth()
	printf("Username (#{Etc.getlogin}): ")
	username = STDIN.gets.chomp
	username = username.length > 1 ? username : Etc.getlogin

	printf("Password for #{username}: ")
	system "stty -echo"
	password = STDIN.gets.chomp
	system "stty echo"
	puts ""
	return {"username" => username || nil, "password" => password || nil}
end

auth = auth()

url = "https://kaos.intuit.com/login"
page = agent.get(url)
login_form = page.form_with :name => nil
login_form.field_with(:name => "username").value = auth["username"]
login_form.field_with(:name => "password").value = auth["password"]
results = agent.submit login_form
if (link = results.link_with(:text => "Profiler Status"))
	account_list = link.click
	account_list.links.each do |link|
		if (link.href =~ /^\/profiler\/([0-9]+)$/)
			account_number = $1
			puts "Querying AWS account #{account_number}"
			output[account_number] = Array.new
			account_info = link.click
			page = Nokogiri::HTML(account_info.body)
			table = page.css("tr")
			table.each do |tr|
				counter = counter + 1
				output[account_number].push({
					"instance_id" => tr.children[0].children[0].text,
					"region" => tr.children[1].children[0].text,
					"ami_id" => tr.children[2].children[0].text,
					"launch_date" => tr.children[3].children[0].text,
					"status" => tr.children[4].children[0].text,
					"reporting" => tr.children[5].children[0].text
				})
			end
		end
	end
end

pp output
puts "#{counter} total instances."
