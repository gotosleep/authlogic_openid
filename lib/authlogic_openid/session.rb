module AuthlogicOpenid
  # This module is responsible for adding all of the OpenID goodness to the Authlogic::Session::Base class.
  module Session
    # Add a simple openid_identifier attribute and some validations for the field.
    def self.included(klass)
      klass.class_eval do
        extend Config
        include Methods
      end
    end

    module Config
      # What method should we call to find an existing openid record?
      # This is useful if you want to store multiple openid_identifiers for a single record.
      # You could do something like:
      #
      #   class User < ActiveRecord::Base
      #     def self.find_existing_openid_registration(openid_identifier, sreg_response, ax_response)
      #       user.first(:conditions => {:openid_identifiers => {:identifier => openid_identifier}})
      #     end
      #   end
      #
      # Obviously the above depends on what you are calling your association, etc. But you get the point.
      #
      # * <tt>Default:</tt> :find_existing_openid_registration
      # * <tt>Accepts:</tt> Symbol
      def find_existing_openid_registration_method(value = nil)
        rw_config(:find_existing_openid_registration_method, value, :find_existing_openid_registration)
      end

      alias_method :find_existing_openid_registration_method=, :find_existing_openid_registration_method

      # Add this in your Session object to Auto Register a new user using openid via sreg
      def auto_register(value=true)
        auto_register_value(value)
      end

      def auto_register_value(value=nil)
        rw_config(:auto_register, value, false)
      end

      alias_method :auto_register=, :auto_register
    end

    module Methods
      def self.included(klass)
        klass.class_eval do
          attr_reader :openid_identifier
          validate :validate_openid_error
          validate :validate_by_openid, :if => :authenticating_with_openid?
        end
      end

      # Hooks into credentials so that you can pass an :openid_identifier key.
      def credentials=(value)
        super
        values = value.is_a?(Array) ? value : [value]
        hash = values.first.is_a?(Hash) ? values.first.with_indifferent_access : nil
        self.openid_identifier = hash[:openid_identifier] if !hash.nil? && hash.key?(:openid_identifier)
      end

      def openid_identifier=(value)
        @openid_identifier = value.blank? ? nil : OpenID.normalize_url(value)
        @openid_error = nil
      rescue OpenID::DiscoveryFailure => e
        @openid_identifier = nil
        @openid_error = e.message
      end

      # Clears out the block if we are authenticating with OpenID, so that we can redirect without a DoubleRender
      # error.
      def save(&block)
        block = nil if !openid_identifier.blank? && controller.request.env[Rack::OpenID::RESPONSE].blank?
        super(&block)
      end

      private
      def authenticating_with_openid?
        attempted_record.nil? && errors.empty? && (!openid_identifier.blank? || (controller.using_open_id? && controller.params[:for_session]))
      end

      def find_existing_openid_registration_method
        self.class.find_existing_openid_registration_method
      end

      def auto_register?
        self.class.auto_register_value
      end

      def validate_by_openid
        self.remember_me = controller.params[:remember_me] == "true" if controller.params.key?(:remember_me)

        options = {
            :required => klass.openid_required_fields,
            :optional => klass.openid_optional_fields,
            :return_to => controller.url_for(:for_session => "1", :remember_me => remember_me?),
            :method => :post}

        controller.send(:authenticate_with_open_id, openid_identifier, options) do |result, openid_identifier, sreg_response, ax_response|
          if result.unsuccessful?
            errors.add_to_base(result.message)
            return
          end

          self.attempted_record = klass.send(find_existing_openid_registration_method, openid_identifier, sreg_response, ax_response)

          if !attempted_record
            if auto_register?
              auto_reg_record = create_open_id_auto_register_record(openid_identifier, sreg_response, ax_response)
              if !auto_reg_record.save_without_session_maintenance
                auto_reg_record.errors.each { |attr, msg| errors.add(attr, msg) }
              else
                self.attempted_record = auto_reg_record
              end
            else
              errors.add(:openid_identifier, "did not match any users in our database, have you set up your account to use OpenID?")
            end
          elsif attempted_record.openid_identifier != openid_identifier
            #update openid_identifier for an existing record
            attempted_record.openid_identifier = openid_identifier
            # should we call map_openid_registration again? I don't think so..
            attempted_record.save_without_session_maintenance
          end
        end
      end

      def create_open_id_auto_register_record(openid_identifier, sreg_response, ax_response)
        returning klass.new do |auto_reg_record|
          auto_reg_record.openid_identifier = openid_identifier
          auto_reg_record.send(:map_openid_registration, sreg_response, ax_response)
        end
      end

      def validate_openid_error
        errors.add(:openid_identifier, @openid_error) if @openid_error
      end
    end
  end
end
