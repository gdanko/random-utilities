#!/usr/bin/ruby

require "pp"
require "time"

class Time
	MINUTE = 60
	HOUR = MINUTE * 60
	DAY = HOUR * 24

	def self.add(number, type, from = nil)
		original_date = from || Time.now
		result = original_date
		d = Date.new(result.year, result.month, result.day)

		case type
		when "sec"
			result = result + number
		when "min"
			result = result + (number * MINUTE)
		when "hour"
			result = result + (number * HOUR)
		when "day"
			result = result + (number * DAY)
		when "month"
			d >>= number
			result = Time.local(d.year, d.month, d.day, result.hour, result.min, result.sec, result.usec)
		when "year"
			d >>= (12 * number)
			result = Time.local(d.year, d.month, d.day, result.hour, result.min, result.sec, result.usec)
		end
	end
	def subtract(number, type, from = nil)
		original_date = from || now
		result = original_date
		d = Date.new(result.year, result.month, result.day)
			
		case type
		when "sec"
			result = result - number
		when "min"
			result = result - (number * MINUTE)
		when "hour"
			result = result - (number * HOUR)
		when "day"
			result = result - (number * DAY)
		when "month"
			d <<= number
			result = Time.local(d.year, d.month, d.day, result.hour, result.min, result.sec, result.usec)
		when "year"
			d <<= (12 * number)
			result = Time.local(d.year, d.month, d.day, result.hour, result.min, result.sec, result.usec)
		end
	end
end

now = Time.new(2002, 10, 31, 2, 2, 2)
puts now
later = Time.add(3, "year", now)
puts later

puts "\n"

now = Time.now
puts now
later = Time.add(3, "year", now)
puts later
