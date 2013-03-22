http = require 'http'
events = require 'events'

apns = require 'apn'
db = require 'mongoose'
express = require 'express'
{OAuth} = require 'oauth'

config = require '../config'

html = new (require 'node-html-encoder').Encoder

db.connect config.db or "mongodb://air:27017/ffapn"

class StreamContext extends events.EventEmitter
  constructor: (@options) ->
    @_stop = false

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

    resp.setEncoding 'utf8'
    resp.on 'close',->
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
            @_dispatch obj
          catch e
            console.info obj
            console.info e.stack
        return

  _dispatch: (data)=>
    @emit 'data',data
    @emit data.event, data

  start: () =>
    return if @_stop
    req = @_makeRequest()
    req.on 'response', @_onResponse
    req.end()

  stop: ()->
    @_stop = true
    @_resp?.destroy()

class APNContext
  constructor: (@options) ->
    @_status =
      streamConnected: false
      lastError: null
      sentNotifications: 0
      lastNotification: 0

    @_stream = new StreamContext @options
    @_device = new apns.Device @options.device_token
    
    @_stream.on 'message.create', @onMessage
    @_stream.on 'friends.create', @onNewFollower
    @_stream.on 'friends.request', @onFriendRequest
    @_stream.on 'fav.create', @onFavourite
    @_stream.on 'dm.create', @onPrivateMessage

    @_stream.on 'connect', () =>
      @_status.streamConnected = true

    @_stream.on 'error', (err) =>
      @_status.streamConnected = false
      @_status.lastError = err

  update: (@options) ->
    @_stream.options = @options
    @_device = new apns.Device @options.device_token

  start: () ->
    @_stream.start()

  stop: () ->
    @_stream.stop()

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
    @sendNotification msg, info

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
    @sendNotification msg, info

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

  sendNotification: (msg,payload) ->
    note = new apns.Notification()
    note.encoding = 'utf8'
    note.expiry = Math.floor(Date.now() / 1000) + 3600
    note.badge = 1
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
    
  config.apn or= {
    cert: 'gohan_apns_production.crt'
    key: 'gohan_apns_production.key'
    gateway: 'gateway.push.apple.com'
  }

  @handleAPNError : (err,notify)=>
    console.info "Error: #{err}"
    console.info JSON.stringify notify
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

schema = db.Schema
  udid:
    type: String
    required: true
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

schema.index user_id:1,udid:1, unique: true

schema.post 'save',(doc) ->
  APNContext.updateOrCreate doc

schema.post 'remove',(doc) ->
  APNContext.removeContext doc

schema.virtual('status').get () ->
  @getContext()?._status or "Context removed or not exist"

schema.methods.getContext = () ->
  APNContext._activeContexts[@_id]

schema.methods.updateProps = (props) ->
  @schema.eachPath (name) =>
    @[name] = props[name] if props.hasOwnProperty name

schema.methods.toJSON = ()->
  id: @_id
  udid: @_udid
  user_id: @user_id
  device_token: @device_token
  oauth_token: @oauth_token
  oauth_secret: @oauth_secret
  consumer_token: @consumer_token
  consumer_secret: @consumer_secret
  flags: @flags
  status: @status
Account = db.model 'Account',schema

app = new express
app.enable 'trust proxy'
app.use express.favicon()
app.use express.logger 'dev'
app.use express.bodyParser()

app.get '/', (req,resp) ->
  resp.redirect 'https://github.com/bearice/ffapn'

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

app.get '/token/:udid/:user_id', (req,resp) ->
  c = {udid: req.params.udid, user_id: req.params.user_id}
  Account.findOne c, (err,obj) ->
    return resp.send 500,err if err
    return resp.send 404,{msg: 'Not found'} unless obj
    resp.json obj

app.get '/token/:udid/:user_id/test', (req,resp) ->
  c = {udid: req.params.udid, user_id: req.params.user_id}
  Account.findOne c, (err,obj) ->
    return resp.send 500,err if err
    return resp.send 404,{msg: 'Not found'} unless obj
    if APNContext.sendTestNotification obj
      return resp.json {msg: "ok"}
    else
      return resp.json {msg: "failed"}

app.post '/token/:udid/:user_id', (req,resp) ->
  console.info req.body
  c = {udid: req.params.udid, user_id: req.params.user_id}
  Account.findOne c, (err,obj) ->
    return resp.send 500,err if err
    obj = new Account c unless obj
    obj.updateProps req.body
    obj.save (err, obj) ->
      return resp.send 500,err if err
      return resp.send 200,obj

app.delete '/token/:udid/:user_id', (req,resp) ->
  c = {udid: req.params.udid, user_id: req.params.user_id}
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
      delay += 10

  console.info "Server started"
  app.listen config.port or 8080, config.bind or "127.0.0.1"
