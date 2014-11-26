#!/usr/bin/ruby

# gem install gir_ffi

require 'gir_ffi'

GirFFI.setup :Vips

# see this to see how to define overrides
# https://github.com/mvz/gir_ffi-gtk/blob/master/lib/gir_ffi-gtk/base.rb

module GirFFIVips
    # Override init to automatically use ARGV as its argument.
    module AutoArgv
        def self.included base
            base.extend ClassMethods
            class << base
                alias_method :init_without_auto_argv, :init
                alias_method :init, :init_with_auto_argv
            end
        end

        # Implementation of class methods for AutoArgv
        module ClassMethods
            def init_with_auto_argv
                puts "in init_with_auto_argv"
                remaining = init_without_auto_argv([$PROGRAM_NAME, *ARGV]).to_a
                remaining.shift
                ARGV.replace remaining
            end
        end
    end
end

# Overrides for Vips module functions
module Vips
    setup_method "init"

    include GirFFIVips::AutoArgv
end
