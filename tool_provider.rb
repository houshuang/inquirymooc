require 'sinatra'
require 'ims/lti'
# must include the oauth proxy object
require 'oauth/request_proxy/rack_request'
require 'redis'
require 'etherpad-lite'
require 'confluence-client'
require 'yaml'
settings = YAML.load_file("settings.yaml")

enable :sessions
set :protection, false

# -----------------------------------
class RedisUser
  def initialize(uname)
    @uname = uname
    @redis = Redis.new()
  end

  attr_accessor :redis

  def get(varstr)
    @redis.get(varfmt(varstr))
  end

  def set(varstr, valstr)
    @redis.set(varfmt(varstr), valstr)
  end

  def varfmt(varstr)
    "#{@uname}:#{varstr}"
  end
end
# -----------------------------------

# the consumer keys/secrets
$oauth_creds = {"test" => "secret", "testing" => "supersecret"}

def wiki_con()
  con = Confluence::Client.new("https://www.encorewiki.org/rpc/xmlrpc")
  con.login(settings['confluence_uname'], settings['confluence_pwd'])
  con
end


def show_error(message)
  @message = message
end

def authorize!
  if key = params['oauth_consumer_key']
    if secret = $oauth_creds[key]
      @tp = IMS::LTI::ToolProvider.new(key, secret, params)
    else
      @tp = IMS::LTI::ToolProvider.new(nil, nil, params)
      @tp.lti_msg = "Your consumer didn't use a recognized key."
      @tp.lti_errorlog = "You did it wrong!"
      show_error "Consumer key wasn't recognized"
      return false
    end
  else
    show_error "No consumer key"
    return false
  end

  if !@tp.valid_request?(request)
    show_error "The OAuth signature was invalid"
    return false
  end

  if Time.now.utc.to_i - @tp.request_oauth_timestamp.to_i > 60*60
    show_error "Your request is too old."
    return false
  end

  # this isn't actually checking anything like it should, just want people
  # implementing real tools to be aware they need to check the nonce
  if was_nonce_used_in_last_x_minutes?(@tp.request_oauth_nonce, 60)
    show_error "Why are you reusing the nonce?"
    return false
  end

  return true
end

def was_nonce_used_in_last_x_minutes?(nonce, minutes=60)
  # some kind of caching solution or something to keep a short-term memory of used nonces
  false
end

# ==========================================================================
# helper functions

def get_wiki_credentials(uname, con = wiki_con())
  redis = RedisUser.new(uname)
  wiki_username = redis.get("wiki_username")
  unless wiki_username then
    callname = redis.get("callname")
    user_number = redis.redis.incr("INQMOOC_USERS")
    wiki_username = "inqmooc_#{user_number}"

    o = [('a'..'z'), ('A'..'Z')].map { |i| i.to_a }.flatten
    wiki_pwd = (0...10).map { o[rand(o.length)] }.join

    redis.set("wiki_username", wiki_username)
    redis.set("wiki_pwd", wiki_pwd)

    con.add_user(wiki_username, callname, "#{wiki_username}@notanemail.com",
      wiki_pwd)
    con.addUserToGroup(wiki_username, "inqmooc")
  else
    wiki_pwd = redis.get("wiki_pwd")
  end
  
  [wiki_username, wiki_pwd]
end

def confluence_url_helper(uname, page)
  wiki_username, wiki_pwd = get_wiki_credentials(@user_id)
  x = "https://www.encorewiki.org/dologin.action?os_username=#{wiki_username}" + 
    "&os_password=#{wiki_pwd}&os_destination=/display/IN/#{page}".
    gsub(" ", "%20")
  p x
  x
end

def log(str)
  redis = Redis.new()
  redis.rpush("#{Time.now}: #{str}")
end
 

# ======================================================================

# routes
# /select_group : initial selection of groups and nickname
# /wiki_template : asks questions, generates wiki page and redirects there,
#                  automatically redirects if template has been created


get '/' do
  erb :index
end

# The url for launching the tool
# It will verify the OAuth signature
post '/select_group' do
  return erb :error unless authorize!
  erb :select_group
end

post '/wiki_template' do
  return erb :error unless authorize!

  @user_id = params['user_id']
  redis = RedisUser.new(@user_id)

  if redis.get("template_done") then
    title = redis.get("template_done")
    redirect(confluence_url_helper(@user_id, title))
  else
    @user_id = params['user_id']
    @group = redis.get("group")
    @callname = redis.get("callname")
    unless @group then
      show_error "You have to sign up for a group first"
      return erb :error
    else
      # It's a launch for grading
      erb :wiki_template
    end
  end
end

post '/start-wiki-page' do
  launch_params = request['launch_params']
  @user_id = launch_params['user_id']
  redis = RedisUser.new(@user_id)

  con = wiki_con()
  wiki_username, wiki_pwd = get_wiki_credentials(@user_id, con)
  
  # create page based on entered info in template
  content = "Category: #{params['category']}\n\nDescription:\n\n#{params['desc']}"
  title = params['tech'].gsub(" ", "%20")

  pg = {"content"=> content,
        "title"=> title,
        "space"=> "IN"}

  con.storePage(pg)
  redis.set("template_done", title)

  # login to confluence and open appropriate page
  redirect(confluence_url_helper(@user_id, title))
end


post '/wiki-notes' do
  return erb :error unless authorize!

  @user_id = params['user_id']
  redis = RedisUser.new(@user_id)
  group = redis.get("group")
  redirect(confluence_url_helper(@user_id, "#{group}-group"))
end


post '/study-group' do
  @group = params['group']
  @callname = params['callname']
  launch_params = request['launch_params']
  @user_id = launch_params['user_id']
  redis = RedisUser.new(@user_id)
  redis.set("group", @group)
  redis.set("callname", @callname)
  return erb :study_group_finished
end

post '/etherpad' do
  return erb :error unless authorize!
  @user_id = params['user_id']
  redis = RedisUser.new(@user_id)
  @group = redis.get("group")
  @callname = redis.get("callname")
  unless @group then
    show_error "You have to sign up for a group first"
    return erb :error
  else
    ether = EtherpadLite.connect('http://etherpad.encorelab.org', settings['etherpad_api_key'], '1.2.1')
    pad = ether.pad(@group)
    pad.text = pad.text + "\n#{Time.now}: Hi, #{@callname}!"

    redirect("http://etherpad.encorelab.org/p/#{@group}")
  end
end


