#!/usr/bin/ruby

require 'vips8'

main_group = GLib::OptionGroup.new 
Vips::add_option_entries main_group

context = GLib::OptionContext.new 
context.set_main_group main_group

context.parse ARGV
