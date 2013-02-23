http = require 'http'
events = require 'events'

apns = require 'apn'
db = require 'mongoose'
express = require 'express'
{OAuth} = require 'oauth'

config = require '../config'

db.connect config.db or "mongodb://air:27017/ffapn"

class StreamContext extends events.EventEmitter
  constructor: (@options) ->
    @_stop = false

  _makeRequest: () ->
    oauth = new OAuth null, null, @options.consumer_token, @options.consumer_secret, "1.0", null, "HMAC-SHA1"
    oauth_header = oauth.authHeader 'http://stream.fanfou.com/1/user.json', @options.oauth_token, @options.oauth_secret
    console.info @options
    console.info oauth_header
    http.request
      host: 'stream.fanfou.com'
      path: '/1/user.json'
      headers:
        'Authorization': oauth_header
      

  _onResponse: (resp)=>
    @_lastChunk = ""
    if resp.code != 200
      @emit 'error', new Error("Bad HTTP status code returned: #{resp.statusCode}")
      return

    resp.setEncoding 'utf8'
    resp.on 'close',->
      setTimeout @start,0

    resp.on 'data',(data)->
      console.info data.length
      @lastChunk += data
      while (pos = lastChunk.indexOf('\r\n')) >= 0
        chunk = @lastChunk.substr(0,pos)
        @lastChunk = @lastChunk.substr(pos+2)
        if chunk != ""
          try
            obj = JSON.parse chunk
            console.info obj.event
            @_dispatch obj
          catch e
            console.error chunk,e
        return

  _dispatch: (data)=>
    @emit data.event, data

  start: () =>
    return if @_stop
    req = @_makeRequest()
    req.on 'response', @_onResponse
    req.end()

  stop: ()->
    @_stop = true
    @_resp.destroy()

class APNContext

  

  constructor: (@options) ->
    @_status =
      sentNotifications: 0
      lastNotification: 0

    @_stream = new StreamContext @options
    @_device = new apns.Device @options.device_token
    
    @_stream.on 'message.create', @onMessage
    @_stream.on 'friends.create', @onNewFollower
    @_stream.on 'friends.request', @onFriendRequest
    @_stream.on 'fav.create', @onFavourite
    @_stream.on 'dm.create', @onPrivateMessage

    @_stream.on 'error', (err) ->
      console.error err

  update: (@options) ->
    @_stream.options = @options

  start: () ->
    @_stream.start()

  stop: () ->
    @_stream.stop()

  onMessage: (evt) =>
    #Filter out events triggered by user
    return unless evt.target.id == @options.user_id
    return unless @options.flags.mention
    msg =
      'loc-key': 'AT'
      'loc-args': [
        evt.source.name,
        evt.object.content.substr(0,40)
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
    msg =
      'loc-key': 'DM'
      'loc-args': [
        evt.source.name,
        evt.object.content.substr(0,40)
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
    msg =
      'loc-key': 'FAV'
      'loc-args': [
        evt.source.name,
        evt.object.content.substr(0,40)
      ]
    info =
      type: 'fav'
      id: evt.object.id
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
    note.device = @device
    note._id = @options._id
    note._ctx = this

    console.info new Buffer(JSON.stringify(note),"utf8")
    APNContext._conn.sendNotification(note)
    @_status.sentNotifications += 1
    @_status.lastNotification = Date.now()
    
  @_conn: new apns.Connection {
    cert: 'gohan_apns_development.crt'
    key: 'gohan_apns_development.key'
    gateway: 'gateway.sandbox.push.apple.com'
    errorCallback: (err,notify)->
        console.info "Error: #{err} "
        console.info JSON.stringify notify

  }

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
      ctx.update(acc)
    else
      ctx = new @(acc)
      @_activeContexts[acc._id] = ctx
      ctx.start()

  @removeContext: (acc) ->
    if ctx = @_activeContexts[acc._id]
      ctx.stop()
    delete @_activeContexts[acc._id]

schema = db.Schema
  udid: String
  user_id: String
  device_token: String
  oauth_token: String
  oauth_secret: String
  consumer_token: String
  consumer_secret: String
  flags: db.Schema.Types.Mixed

schema.index user_id:1,udid:1, unique: true

schema.post 'save',(doc) ->
  APNContext.updateOrCreate doc

schema.post 'remove',(doc) ->
  APNContext.removeContext doc

schema.virtual('status').get () ->
  @getContext._status

schema.methods.getContext = () ->
  APNContext._activeContexts[@_id]

schema.methods.updateProps = (props) ->
  @schema.eachPath (name) =>
    @[name] = props[name] if props.hasOwnProperty name

Account = db.model 'Account',schema

app = new express
app.enable 'trust proxy'
app.use express.favicon()
app.use express.logger 'dev'
app.use express.bodyParser()

app.get '/', (req,resp) ->
  resp.redirect 'http://imach.me/gohanapp'

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
    APNContext.updateOrCreate obj for obj in arr

  console.info "Server started"
  app.listen config.port or 8080, config.bind or "127.0.0.1"
