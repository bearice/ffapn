http = require 'http'
events = require 'events'

apns = require 'apn'
db = require 'mongoose'
express = require 'express'
{OAuth} = require 'oauth'

config = require '../config'

html = new (require 'node-html-encoder').Encoder

db.connect config.db or "mongodb://air:27017/ffapn"

_status =
  boot_time: (new Date).valueOf()
  users: 0
  live_users: 0
  messages: 0
  pushed_messages: 0
  errors: 0
  connected_streams: 0

getStatus = (fn) ->
  _status.uptime = (new Date).valueOf() - _status.boot_time
  fn _status

class StreamContext extends events.EventEmitter
  streams = {}

  @getStream = (option) ->
    uid = @options.user_id
    if streams[uid] then return streams[uid]
    streams[uid] = new StreamContext(options)

  constructor: (@options) ->
    @_refcnt = 0

  _makeRequest: () ->
    oauth = new OAuth null, null, @options.consumer_token, @options.consumer_secret, "1.0", null, "HMAC-SHA1"
    oauth_header = oauth.authHeader 'http://stream.fanfou.com/1/user.json', @options.oauth_token, @options.oauth_secret
    http.request
      agent: false
      host: 'stream.fanfou.com'
      path: '/1/user.json'
      headers:
        'Authorization': oauth_header
      
  _onResponse: (resp)=>
    @_resp = resp
    @lastChunk = ""
    if resp.statusCode != 200
      console.info "Stream NOT connected for #{@options.udid}/#{@options.user_id} Got HTTP #{resp.statusCode}"
      @emit 'error', new Error("Bad HTTP status code returned: #{resp.statusCode}")
      return

    console.info "Stream connected for #{@options.udid}/#{@options.user_id}"
    @emit 'connect',this
    _status.connected_streams++

    resp.setEncoding 'utf8'
    resp.on 'close',->
      _status.connected_streams--
      @emit 'disconnect', this
      setTimeout @start,0

    resp.on 'data',(data) =>
      @lastChunk += data
      while (pos = @lastChunk.indexOf('\r\n')) >= 0
        chunk = @lastChunk.substr(0,pos)
        @lastChunk = @lastChunk.substr(pos+2)
        if chunk != ""
          try
            obj = JSON.parse chunk
            console.info obj.event
            _status.messages++
            @_dispatch obj
          catch e
            console.info chunk
            console.info e.stack
        return

  _dispatch: (data)=>
    @emit 'data',data

  start: () =>
    @_refcnt++
    if @_refcnt is 1
      req = @_makeRequest()
      req.on 'response', @_onResponse
      req.end()

  stop: ()->
    @_refcnt--
    if @_refcnt is 0
      @_resp?.destroy()
      streams[@options.user_id] = null

class APNContext
  constructor: (@options) ->
    @_status =
      streamConnected: false
      lastError: null
      sentNotifications: 0
      lastNotification: 0

    @_device = new apns.Device @options.device_token
    

  start: () ->
    _status.live_users++
    @_stream = StreamContext.getStream @options
    @_stream.on 'connect', @onStreamConnected
    @_stream.on 'error', @onStreamError
    @_stream.on 'data', @onData
    @_stream.start()

  stop: () ->
    _status.live_users--
    @_stream.stop()
    @_stream.removeListener 'connect', @onStreamConnected
    @_stream.removeListener 'error', @onStreamError
    @_stream.removeListener 'data', @onData
    @_stream = null

  onStreamConnected: () =>
    @_status.streamConnected = true

  onStreamError: () =>
    @_status.streamConnected = false
    @_status.lastError = err

  onData: (obj) =>
    switch obj.event
      when 'message.create'  then @onMessage obj
      when 'friends.create'  then @onNewFollower obj
      when 'friends.request' then @onFriendRequest obj
      when 'fav.create'      then @onFavourite obj
      when 'dm.create'       then @onPrivateMessage obj
    
  onMessage: (evt) =>
    #Filter out events triggered by user
    return if evt.source.id == @options.user_id
    return unless @options.flags.mention
    body = html.htmlDecode evt.object.text
    msg =
      'loc-key': 'AT'
      'loc-args': [
        evt.source.name,
        body.substr(0,40)
      ]
    info =
      type: 'at'
      id: evt.object.id
      user: @options.user_id
    @sendNotification msg, info

  onPrivateMessage: (evt) =>
    #Filter out events triggered by user
    return unless evt.target.id == @options.user_id
    return unless @options.flags.direct_message
    body = html.htmlDecode evt.object.text
    msg =
      'loc-key': 'DM'
      'loc-args': [
        evt.source.name,
        body.substr(0,40)
      ]
    info =
      type: 'dm'
      id: evt.object.id
      user: @options.user_id
    @sendNotification msg, info

  onFavourite: (evt) =>
    #Filter out events triggered by user
    return unless evt.target.id == @options.user_id
    return unless @options.flags.favourite
    body = html.htmlDecode evt.object.text
    msg =
      'loc-key': 'FAV'
      'loc-args': [
        evt.source.name,
        body.substr(0,40)
      ]
    info =
      type: 'fav'
      id: evt.source.id
      user: @options.user_id
    @sendNotification msg, info, 0

  onNewFollower: (evt) =>
    #Filter out events triggered by user
    return unless evt.target.id == @options.user_id
    return unless @options.flags.follow_create
    msg =
      'loc-key': 'NF'
      'loc-args': [
        evt.source.name
      ]
    info =
      type: 'nf'
      id: evt.source.id
      user: @options.user_id
    @sendNotification msg, info, 0

  onFriendRequest: (evt) =>
    #Filter out events triggered by user
    return unless evt.target.id == @options.user_id
    return unless @options.flags.follow_request
    msg =
      'loc-key': 'FR'
      'loc-args': [
        evt.source.name,
      ]
    info =
      type: 'fr'
      id: evt.source.id
      user: @options.user_id
    @sendNotification msg, info

  onExpiry: () =>
    msg =
        'loc-key': 'EXPIRY'
        'loc-args': []
    info =
        type: 'expiry'
        user: @options.user_id

    @sendNotification msg,info
    return true

  sendNotification: (msg,payload,badge=1) ->
    note = new apns.Notification()
    note.encoding = 'utf8'
    note.expiry = Math.floor(Date.now() / 1000) + 3600
    note.badge = badge
    note.sound = "default"
    note.alert = msg
    note.payload = payload
    note.device = @_device
    note._id = @options._id
    note._ctx = this

    #trim msg body
    size = note.length()
    while size > 255
      str = msg['loc-args'][1]
      msg['loc-args'][1] = str.substr(0,str.length-1)
      size = note.length()

    #console.info note
    console.info "user: #{@options.user_id} type:#{payload.type} size: #{size}"
    APNContext._conn.sendNotification(note)
    @_status.sentNotifications += 1
    @_status.lastNotification = Date.now()
    _status.pushed_messages++
    
  config.apn or= {
    cert: 'gohan_apns_production.crt'
    key: 'gohan_apns_production.key'
    gateway: 'gateway.push.apple.com'
  }

  @handleAPNError : (err,notify)=>
    console.info "Error: #{err}"
    console.info JSON.stringify notify
    _status.errors++
    if notify?._ctx
      notify._ctx._status.lastError = "APNServer error: "+ err
      if err == 8
        @removeContext notify._ctx.options

  config.apn.errorCallback = @handleAPNError.bind(APNContext)
  @_conn: new apns.Connection config.apn
  @_activeContexts: {}
 
  @sendTestNotification: (acc)->
    if ctx = @_activeContexts[acc._id]
      msg =
        'loc-key': 'TEST_NOTIFICATION_MESSAGE'
        'loc-args': []
      info =
        type: 'test'
        id: Date.now()

      ctx.sendNotification msg,info
      return true
    else
      return false

  @updateOrCreate: (acc) ->
    if ctx = @_activeContexts[acc._id]
      console.info "Update settings for #{acc.udid}/#{acc.user_id}..."
      ctx.update(acc)
    else
      console.info "Try to connect #{acc.udid}/#{acc.user_id}..."
      ctx = new @(acc)
      @_activeContexts[acc._id] = ctx
      ctx.start()

  @removeContext: (acc) ->
    console.info "Removing context #{acc.udid}/#{acc.user_id}..."
    if ctx = @_activeContexts[acc._id]
      ctx.stop()
    delete @_activeContexts[acc._id]
    try
      acc.remove()
    catch e
      console.info(e)

schema = db.Schema
  user_id:
    type: String
    required: true
  device_token:
    type: String
    required: true
  oauth_token:
    type: String
    required: true
  oauth_secret:
    type: String
    required: true
  consumer_token:
    type: String
    required: true
  consumer_secret:
    type: String
    required: true
  flags:
    type: db.Schema.Types.Mixed
    required: true
  last_seen:
    type: Date
    required: true
    index: true

schema.index {user_id:1, device_token:1}, unique: true

schema.pre 'save',(next) ->
  @last_seen = new Date unless @last_seen

schema.post 'save',(doc) ->
  APNContext.updateOrCreate doc

schema.post 'remove',(doc) ->
  APNContext.removeContext doc

schema.virtual('udid').get () -> @device_token
schema.virtual('status').get () ->
  @getContext()?._status or "Context removed or not exist"

schema.methods.getContext = () ->
  APNContext._activeContexts[@_id]

schema.methods.updateProps = (props) ->
  @schema.eachPath (name) =>
    @[name] = props[name] if props.hasOwnProperty name

schema.methods.touch = () ->
  @last_seen = new Date

schema.methods.toJSON = () ->
  id: @_id
  user_id: @user_id
  device_token: @device_token
  oauth_token: @oauth_token
  oauth_secret: @oauth_secret
  consumer_token: @consumer_token
  consumer_secret: @consumer_secret
  flags: @flags
  status: @status

schema.statics.purgeAccounts = () ->
  date = new Date
  date.setDate(date.getDate() - 7)

  @where('last_seen').lt(date).exec (err,objs) ->
    if err
      console.error err
      return
    for obj in objs
      obj.getContext().onExpiry()
      obj.remove()

Account = db.model 'Account',schema

app = new express
app.enable 'trust proxy'
app.use express.favicon()
app.use express.logger 'dev'
app.use express.bodyParser()

app.get '/', (req,resp) ->
  resp.redirect 'https://github.com/bearice/ffapn'

app.get '/status', (req,resp) ->
  getStatus resp.send.bind resp

app.get '/test/:token', (req,resp) ->
  msg =
    'loc-key': 'TEST_NOTIFICATION_MESSAGE'
    'loc-args': []
  info =
    type: 'test'
    id: Date.now()
  note = new apns.Notification()
  note.encoding = 'utf8'
  note.expiry = Math.floor(Date.now() / 1000) + 3600
  note.sound = "default"
  note.alert = msg
  note.payload = info
  note.device = new apns.Device(req.params.token)

  APNContext._conn.sendNotification(note)
  resp.send {msg:"ok"}

app.get '/token/:token/:user_id', (req,resp) ->
  c = {device_token: req.params.token, user_id: req.params.user_id}
  Account.findOne c, (err,obj) ->
    return resp.send 500,err if err
    return resp.send 404,{msg: 'Not found'} unless obj
    resp.json obj

app.get '/token/:token/:user_id/test', (req,resp) ->
  c = {device_token: req.params.token, user_id: req.params.user_id}
  Account.findOne c, (err,obj) ->
    return resp.send 500,err if err
    return resp.send 404,{msg: 'Not found'} unless obj
    if APNContext.sendTestNotification obj
      return resp.json {msg: "ok"}
    else
      return resp.json {msg: "failed"}

app.post '/token/:token/:user_id', (req,resp) ->
  console.info req.body
  c = {device_token: req.params.token, user_id: req.params.user_id}
  Account.findOne c, (err,obj) ->
    return resp.send 500,err if err
    obj = new Account c unless obj
    obj.updateProps req.body
    obj.touch()
    obj.save (err, obj) ->
      return resp.send 500,err if err
      return resp.send 200,obj

app.delete '/token/:token/:user_id', (req,resp) ->
  c = {device_token: req.params.token, user_id: req.params.user_id}
  Account.findOne c, (err,obj) ->
    return resp.send 500,err if err
    return resp.send 404,{msg: 'Not found'} unless obj
    obj.remove()

Account.find (err,arr) ->
  console.info err if err
  if arr
    console.info "Loading accounts: #{arr.length}"
    delay = 0
    for obj in arr
      setTimeout APNContext.updateOrCreate.bind(APNContext,obj) ,delay
      delay += 50

  setInterval Account.purgeAccounts.bind(Account), 3600*1000

  console.info "Server started"
  app.listen config.port or 8080, config.bind or "127.0.0.1"
