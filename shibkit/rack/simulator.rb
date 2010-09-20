##
##
module Shibkit
  
  module Rack
  
    class Simulator
  
      require 'uuid'
      require 'haml'
      require 'yaml'
      require 'time'
      require 'rack/logger'
      
      ## Default record filter mixin code
      require 'shibkit/rack/simulator/record_filter'
      
      ## Easy access to Shibkit's configuration settings
      include Shibkit::Configured
    
      ## Middleware application components and behaviour
      CONTENT_TYPE   = { "Content-Type" => "text/html; charset=utf-8" }
      VIEWS          = [:user_chooser, :fatal_error]
  
      def initialize(app)
      
        ## Rack app
        @app = app

        ## Initial vars for storing cached data
        @views    = nil
        @users    = nil
        @orgtree  = nil 
      
        ## Can Chooser IDPs have Single Sign On? # TODO needs per-IDP settings too
        @sso = config.sim_chooser_idp_sso
        
        ## Add the record processing mixin if it's present
        load_filter_mixin
      
        ## Load and cache the data sources for users and chooser organisations
        user_data
      
        ## Load the Federation and org/IDP data
        # ...
      
        ## Check that everything is OK
        check_state # TODO: check for working session
      
      end
  
      ## Selecting an action and returning to the Rack stack 
      def call(env)
      
        ## Peek at user input, they might be talking to us
        request = ::Rack::Request.new(env)
      
        begin

          ## First act according the the URL path selected by user
          case request.path
          
          ## Request is for the fake IDP's login function
          when sim_idp_login_path
          
            ## Where do we send users to after they authenticate with IDP?
            destination = request.params['destination'] || '/'
          
            ## Specified a user? (GET or POST)
            user_id = request.params['user']
            
            if user_id 
              
              log_debug("(IDP) New user authentication requested")
              
              ## Get our user information using the param
              user_details = users[user_id.to_s]
            
              ## Check user info is acceptable
              unless user_details_ok?(user_details)
              
                log_debug("(IDP) User authentication failed - requested user not found")
              
                ## User was requested but no user details were found
                message = "User with ID '#{user_id}' could not be found!"
                http_status_code = 401
              
                return user_chooser_action(env, { :message => message, :code => code })
              
              end
            
              ## 'Authenticate', create sim IDP/SP session
              set_session(env, user_details)

              ## Clean up
              tidy_request(env)

              log_debug("(IDP) User authentication succeeded.")
 
              ## Redirect back to original URL
              return [ 302, {'Location'=> destination }, [] ]

            else
              
              ## Has not specified a user. So, already got a shibshim session? (shared by fake IDP and fake SP)
              if existing_idp_session?(env) and @sso

                log_debug("(IDP) User already authenticated. Redirecting back to application")

                return [ 302, {'Location'=> destination }, [] ]

              end
              
              ## Not specified a user and not got an existing session, so ask user to 'authenticate'
              log_debug("(IDP) Not already authenticated. Storing destination and showing Chooser page.")

              ## Tidy up
              tidy_request(env)
            
              ## Show the chooser page    
              return user_chooser_action(env)
         
            end
        
          ## Request is for the fake IDP's logout URL
          when sim_idp_logout_path
          
            ## Kill session
            reset_sessions(env) 
          
            log_debug("(IDP) Reset session, redirecting to IDP login page")
          
            ## Redirect to IDP login (or wayf)
            return [ 302, {'Location'=> sim_idp_login_path }, [] ]
        
          ## Request is for the fake WAYF
          when sim_wayf_path
          
            ## Specified an IDP?

          
            ## Redirect to IDP with Org type in session or something

            
            ## Not specified an IDP

          
            ## Show WAYF page

        
          ## Gateway URL? Could cover whole application or just part
          when sim_sp_path_regex 

            ## Has user already authenticated with the SP? If so we can simulate SP header injection
            if existing_sp_session? env
              
              ## TODO: SP sessions should expire
              
              log_debug("(SP)  Already authenticated with IDP and SP so injecting headers and calling application")
            
              ## Get our user information using the param
              sp_user_id = sim_sp_session(env)[:user_id]
              user_details = users[sp_user_id.to_s]
            
              ## Inject headers
              inject_sp_headers(env, user_details)
            
              ## Pass control up to higher Rack middleware and application
              return @app.call(env)
            
            end
            
            ## If the user has IDP session but not SP, we need to authenticate them at SP # TODO: possibly make this DRYer, or leave clearer?
            if existing_idp_session? env
              
              ## TODO: IDP sessions should expire
              
              log_debug("(SP)  Already authenticated with IDP but not SP, so authenticating with SP now.")
            
              ## Mark this user as authenticated with SP, so we can detect changed users, etc
              idp_user_id = sim_idp_session(env)[:user_id]
              sp_user_id = idp_user_id
              sim_sp_session(env)[:user_id] = sp_user_id
              
              ## Get user details
              user_details = users[sp_user_id.to_s]
              
              ## Inject headers
              inject_sp_headers(env, user_details)
              
              ## Pass control up to higher Rack middleware and application
              return @app.call(env)
              
            end
            
            ## If the user has neither an SP session or IDP session then they need one!
            log_debug("(SP)  No suitable IDP/SP sessions found, so redirecting to IDP to authenticate")
            
            ## Tidy up session to make sure we start from nothing (may have inconsistent, mismatched SP & IDP user ids)
            reset_sessions(env)
            
            ## Store original destination URL
            destination = ::Rack::Utils.escape(request.url)

            ## Redirect to fake IDP URL (or wayf, later)
            return [ 302, {'Location'=> "#{sim_idp_login_path}?destination=#{destination}" }, [] ]


          ## If not a special or authenticated URL
          else
         
           ## Behave differently if in gateway mode? TODO
           log_debug("(SP)  URL not behind the SP, so just calling application")
         
           ## Pass control up to higher Rack middleware and application
           return @app.call(env)
         
          end
        
        ## Catch any errors generated by this middleware class. Do not catch other Middleware errors.
        rescue Rack::Simulator::RuntimeError => oops
        
          ## Render a halt page
          return fatal_error_action(env, oops)
    
        end

      end
  
      private
  
      ## Wipe clean the Rack session info for this middleware (SP and IDP)
      def reset_sessions(env)

       sim_sp_session(env).replace  Hash.new
       sim_idp_session(env).replace Hash.new
       
       tidy_request(env)
    
      end
      
      ## Remove all injected headers
      def flush_headers(env)
      
        # TODO
        # ...
      
      end
      
      ## Error page for unrecoverable situations
      def fatal_error_action(env, oops)
      
        log_debug("****  Fatal error: #{oops}")
      
        unless ENV['RACK_ENV'] == :production or ENV['RAILS_ENV'] == :production

          puts "\nBacktrace is:\n#{oops.backtrace.to_yaml}\n"

        end
    
        render_locals = { :message => oops.to_s }
        page_body = render_page(:fatal_error, render_locals)
    
        return 500, CONTENT_TYPE, [page_body.to_s]
    
      end
  
      ## Controller for user presentation page
      def user_chooser_action(env, options={}) 
    
         message = options[:message] 
         code    = options[:code].to_i || 200
    
         render_locals = { :organisations => organisations, :users => users,
                           :message => message, :idp_path => sim_idp_login_path }
         page_body = render_page(:user_chooser, render_locals)
       
         return code, CONTENT_TYPE, [page_body.to_s]
    
      end
  
      ## Display a chooser page
      def render_page(view, locals={})
    
        ## HAML rendering options
        Haml::Template.options[:format] = :html5
    
        ## Render and return the page
        haml = Haml::Engine.new(views[view])
        return haml.render(Object.new, locals)
    
      end
  
      ## Add attribute information to the headers passed to application
      def inject_attribute_headers(env, user_details)
      
        ## The ID of this simulated SP # TODO: needs to be defined in config
        sp_id = config.sim_sp_entity_id
      
        ## Convert to proper format that matches the live SP (also add new ones)
        prepared_data = process_attribute_data(user_details)
    
        ## Now the useful bit
        prepared_data.each_pair do | header, value| 
      
          env[header] = value
      
        end
      
        ## Inject the rather important eptid varieties
        env['targeted-id']   = prepared_data['targeted_id']   || 
          Shibkit::DataTools.targeted_id(user_details['id'], sp_id, user_details['idp_scope'], user_details['idp_salt'], type=:computed)
        env['persistent-id'] = prepared_data['persistent_id'] ||
          Shibkit::DataTools.persistent_id(user_details['id'], sp_id, user_details['idp_id'], user_details['idp_salt'], type=:computed)
        
        ## Cache the persistent ID for this user
        user_details['persistent_id'] = env['persistent-id']
 
      end

      ## Add attribute information to the headers passed to application
      def inject_session_headers(env, user_details)
      
        ## The ID of this simulated SP # TODO: needs to be defined in config
        sp_id = config.sim_sp_entity_id
      
        ## Application ID
        env['Shib-Application-ID'] = 'default'
    
        ## Persistent Session ID
        session_id = sim_sp_session(env)[:sessionid]
        env['Shib-Session-ID'] = session_id
    
        ## Identity Provider ID
        env['Shib-Identity-Provider'] = sp_id
    
        ## Time authentication occured
        env['Shib-Authentication-Instant'] = sim_sp_session(env)[:logintime]
    
        ## Keep login method rather vague
        env['Shib-Authentication-Method'] = 'urn:oasis:names:tc:SAML:1.0:am:unspecified'
        env['Shib-AuthnContext-Class']    = 'urn:oasis:names:tc:SAML:1.0:am:unspecified'
    
        ## Assertion headers are cargo-culted for not (not sensible - Do Not Use)
        assertion_header_info(session_id, user_details).each_pair {|header, value| env[header] = value}
        env['Shib-Assertion-Count'] = "%02d" % assertion_header_info(session_id, user_details).size
    
        ## Is targeted ID set to be automatic?
        env['REMOTE_USER'] = user_details['persistent_id'] ||
          Shibkit::DataTools.persistent_id(user_details['id'], sp_id, user_details['idp_id'], user_details['idp_salt'], type=:computed)
     
      end
  
      ## Munge the data in attributes to match Shib/SAML expectations
      def process_attribute_data(user_details)
    
        munged_data = user_details.dup
    
        ## Call out to filter (this is monkey patched by shibsim_filter.rb)
        munged_data = user_record_filter(munged_data)
          
        return munged_data
    
      end
    
      ## User-overridable method - monkey patch with shibsim_filter.rb
      def user_record_filter(munged_data)
      
        return munged_data
      
      end
    
  
      ## Create information for mocking assertion headers
      def assertion_header_info(session_id, user_details) 
    
        info = Hash.new
      
        ## We need this again in order to calculate accurate assertion size
        munged_data = process_attribute_data(user_details)
      
        ## This should be based on total size of assertion data I believe (this is Shib1.3 style?)
        (1..2).each do |assertion_part|
      
          ## Each assertion fragment gets a numbered identifier
          header = 'Shib-Assertion-' + "%02d" % assertion_part
      
          ## Building up a mock URL
          value  = config.sim_assertion_base + '?key=' + session_id + '&ID=' + Shibkit::DataTools.xsid
    
          ## Collect it
          info[header] = value
      
        end
    
        return info
  
      end
  
      ## Create the SP/IDP basic session
      def set_session(env, user_details)
        
        ## Keep the user ID so we can reapply attributes in the future
        sim_idp_session(env)[:user_id] = user_details['id']
      
        ## Contruct a session ID is if we don't have one
        sim_sp_session(env)[:sessionid] = Shibkit::DataTools.xsid
    
        ## Store login time as a string in xs:DateTime format (with no timezone for some reason)
        sim_sp_session(env)[:logintime] = Time.new.xmlschema.gsub(/(\+.*)/, 'Z')

    
      end
      
      ## Access simulated IDP session information
      def sim_idp_session(env)
        
        ## Make sure we have a data structure
        env['rack.session']['shibkit-simulator']        ||= Hash.new
        env['rack.session']['shibkit-simulator']['idp'] ||= Hash.new
        
        return env['rack.session']['shibkit-simulator']['idp']
        
      end
      
      ## Access simulated SP session information
      def sim_sp_session(env)
   
        ## Make sure we have a data structure
        env['rack.session']['shibkit-simulator']        ||= Hash.new
        env['rack.session']['shibkit-simulator']['sp'] ||= Hash.new
       
        return env['rack.session']['shibkit-simulator']['sp']
        
      end
      
      ## Inject headers into session as if provided by a real SP
      def inject_sp_headers(env, user_details)
        
        raise Rack::Simulator::RuntimeError, "Missing user details when trying to add SP headers" unless user_details
        
        ## Inject data into the headers that application will receive
        inject_attribute_headers(env, user_details)
    
        ## Fake various Shibboleth headers that are session-specific
        inject_session_headers(env, user_details)
    
      end

      ## Remove ShibSimulator params, etc from request before it reaches application
      def tidy_request(env)
    
        #req = Rack::Request.new(env)
    
        #[:shibsim_user, :shibsim_reset].each do |param|
    
        #  req.params.delete(param.to_s)
    
       # end
    
      end
  
      ## List user records by ID
      def users
    
        return user_data[0]
  
      end
  
      ## List user records by ID
      def organisations
  
        return user_data[1]
  
      end

      ## Load and prepare HAML views
      def views
    
        unless @views
    
          @views = Hash.new
    
          VIEWS.each do |view| 

            view_file_location = "#{::File.dirname(__FILE__)}/simulator/views/#{view.to_s}.haml"
            @views[view] = IO.read(view_file_location)

          end
    
        end
    
        return @views
    
      end
  
      ## Provide user data for chooser and header injection
      def user_data
    
        unless @users && @orgtree
    
          @users   = Hash.new
          @orgtree = Hash.new 
      
          user_fixture_file_location = "#{::File.dirname(__FILE__)}/simulator/default_data/users.yml"

          fixture_data = YAML.load_file(config.sim_users_file )

          fixture_data.each_pair do |label, record| 
 
            record['shibsim_label'] = label.to_s.strip
            rid  = record['id'].to_s
            rorg = record['organisation'].to_s.strip
          
            ## Salt to use is based on org name
            record['idp_salt'] = Digest::SHA1.digest(rorg).chomp # TODO: make configurable
          
            @users[rid]    =   record        
            @orgtree[rorg] ||= Array.new
        
            @orgtree[rorg] <<  record 
        
          end
 
        end

        return [@users, @orgtree]
    
      end
    
      ## Add the filter mixin if it exists
      def load_filter_mixin
      
        eval "extend #{config.sim_record_filter_module}"
      
      end
    
      def check_state
      
        raise "No user data!" unless @users.size > 0 
        raise "No organisation labels!" unless @orgtree.size > 0
      
      end
    
      ## Simple and switchable logger (to stdout by default)
      def log_debug(message)
        
        return unless config.sim_debug
        
        puts [Time.new, "Shibkit-Simulator:", message].join(' ')
      
      end

      ## Does an 'IDP' session exist already?
      def existing_idp_session?(env)
      
        ## Look for evidence of existing session: Has the fake IDP 'authenticated'?
        return true if env["rack.session"] and
          env["rack.session"]['shibkit-simulator'] and
          env["rack.session"]['shibkit-simulator']['idp'] and
          env["rack.session"]['shibkit-simulator']['idp'][:user_id] and 
          env["rack.session"]['shibkit-simulator']['idp'][:user_id].to_i > 0
        
        
        
        # ...
        
        return false
      
      end
    
      ## Does an 'SP' session exist already?
      def existing_sp_session?(env)
    
        ## Has the fake IDP 'authenticated'?
        return false unless env["rack.session"] and
          env["rack.session"]['shibkit-simulator'] and
          env["rack.session"]['shibkit-simulator']['sp'] and
          env["rack.session"]['shibkit-simulator']['sp'][:user_id] and 
          env["rack.session"]['shibkit-simulator']['sp'][:user_id].to_i > 0
        
        # ...
        
        ## Check that the *same* user has already authenticated with the fake SP too.
        return true if env["rack.session"]['shibkit-simulator']['idp'][:user_id].to_i == 
          sim_sp_session(env)[:user_id].to_i
        
        return false
      
      end
    
      ## Is the requested user valid?
      def user_details_ok?(user_details)
      
        return true if user_details and user_details.kind_of?(Hash) and
            user_details.size > 1 
      
        return false
      
      end
      
      ## Define various URL matchers
      def sim_idp_login_path
      
        return "/shibsim_idp/login"
      
      end
    
      def sim_idp_logout_path
      
        return "/shibsim_idp/logout"
      
      end

      def sim_wayf_path
      
        return "/shibsim_wayf"
    
      end

      def sim_sp_path_regex
      
        regex = /.*/
        
        return regex
      
    
      end

      ## Exception class used here to limit rescued errors to this middleware only
      class Rack::Simulator::RuntimeError < Shibkit::RackMiddlewareError 
    
      end
    
    end

  end
end