require 'dotenv'
require 'sinatra'
require 'shopify_api'
require 'httparty'
require 'pry'

class GoodieBasket < Sinatra::Base

	def initialize
		Dotenv.load
		@key = ENV['API_KEY']
		@secret = ENV['API_SECRET']
		@app_url = "drewbie.ngrok.io"
		@tokens = {}
		super
	end

	get '/goodiebasket/install' do
		shop = params[:shop]
		scopes = "read_products,write_products,read_orders"

		install_url = "https://#{shop}/admin/oauth/authorize?client_id=#{@key}&scope=#{scopes}&redirect_uri=https://#{@app_url}/goodiebasket/auth"
		redirect install_url
	end

	get '/goodiebasket/auth' do
		shop = params[:shop]
		hmac = params[:hmac]
		code = params[:code]

		query = params.reject{|k,_| k == 'hmac'}
		message = Rack::Utils.build_query(query)
		digest = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), @secret, message)

		puts "digest: #{digest}"

		if not (hmac == digest)
			return [401, "Authorization failed!"]
		end


		if @tokens[shop].nil?

			response = HTTParty.post("https://#{shop}/admin/oauth/access_token",
				body: { client_id: @key, client_secret: @secret, code: code})

			puts response.code
			puts response

			if (response.code == 200)
				@tokens[shop] = response['access_token']
			else
				return [500, "No Bueno"]
			end
		end

		# create session with shop, token
		session = ShopifyAPI::Session.new(shop, @tokens[shop])
		# activate session
		ShopifyAPI::Base.activate_session(session)
		ShopifyAPI::Webhook.create("topic": "orders\/create", "address": "https:\/\/drewbie.ngrok.io\/goodiebasket\/webhook", "format": "json")
			
		
		create_recurring_application_charge
		
		redirect '/goodiebasket'


	end



	get '/goodiebasket' do
		@products = ShopifyAPI::Product.find(:all)
	erb :index
  end

  post '/goodiebasket' do
    @basket = params[:basket]
    @gifts = params[:gifts]
    puts @basket
		puts @gift
		parent_variant = ShopifyAPI::Variant.find(@basket)

		parent_variant.add_metafield(ShopifyAPI::Metafield.new({
		"namespace": "gifts",
		"key": "gifts",
		"value": "#{@gifts}",
		"value_type": "string"
			}))

	end

	get '/activatecharge' do
    charge_id  = request.params['charge_id']
    recurring_application_charge = ShopifyAPI::RecurringApplicationCharge.find(charge_id)
    recurring_application_charge.status == "accepted" ? recurring_application_charge.activate : "Please accept the charge"

    puts 'Charge activated!'
    redirect '/goodiebasket'

  end

	helpers do
		def verify_webhook(data, hmac_header)
			digest = OpenSSL::Digest.new('sha256')
			calculated_hmac = Base64.encode64(OpenSSL::HMAC.digest(digest, @secret, data)).strip
			calculated_hmac == hmac_header
		end
	

		def create_recurring_application_charge
	    if not ShopifyAPI::RecurringApplicationCharge.current
	      @recurring_application_charge = ShopifyAPI::RecurringApplicationCharge.new(
	        name: "Goodie Basket Plan",
	        price: 14.99,
	        return_url: "https:\/\/drewbie.ngrok.io\/activatecharge",
	        test: true,	
	        capped_amount: 100,
	        terms: "$1 for every order created")

	      if @recurring_application_charge.save
	      	puts 'Application charge created!'
	        redirect @recurring_application_charge.confirmation_url
	      #else
	      #	puts 'Application charge already exists.'
	      #	redirect '/goodiebasket'
	      end
	    end
	  end
	  def create_usage_charge
      usage_charge = ShopifyAPI::UsageCharge.new(description: "1 dollar per order plan", price: 1.0)
      recurring_application_charge_id = ShopifyAPI::RecurringApplicationCharge.last
      usage_charge.prefix_options = {recurring_application_charge_id: recurring_application_charge_id.id}
      usage_charge.save
      puts "Usage charge created successfully!" 
		end
	end

	post '/goodiebasket/webhook' do
		request.body.rewind
		data = request.body.read
		verified = verify_webhook(data, env["HTTP_X_SHOPIFY_HMAC_SHA256"])
		shop = env["HTTP_X_SHOPIFY_SHOP_DOMAIN"]
		token = @tokens[shop]
		puts env

		puts "Webhook verified: #{verified}"

		if not verified
			return [401, "Webhook not verified"]
		end

		# Otherwise, webhook is verified:
		ShopifyAPI::Session.temp(shop, token) {
		create_usage_charge
		puts 'usage charge created'
		json_data = JSON.load data

		line_items = json_data['line_items']

		line_items.each do |line_item|
			variant_id = line_item['variant_id']

			variant = ShopifyAPI::Variant.find(variant_id)

			variant.metafields.each do |field|
				if field.key == 'gifts'
					puts 'test'
					items = field.value.split(',')

					items.each do |item|
						goodie = ShopifyAPI::Variant.find(item)
						goodie.inventory_quantity = goodie.inventory_quantity - 1
						goodie.save
					
					end

				end

			end
			
		end
		return [200, "All good brah"]
	}
	end
end

GoodieBasket.run!
