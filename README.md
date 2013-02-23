FFAPN
===

The missing push support for fanfou.com

API Interface
---

Client should HTTP API to register or remove push contexts

###GET /token/:udid/:user_id

Return push context status

---

###POST /token/:udid/:user_id

Create a new push context, or modify a existing context.

Arguments passed in post payload, content-type should be application/json

look at the example below:

```
POST /token/1234567890/test
Host: gohan.ffapn.icybear.net
Content-type: application/json

{
	"device_token":"000",
	"oauth_token":"111",
	"oauth_secret":"222",
	"consumer_token":"333",
	"consumer_secret":"444",
	"flags": {
		"mention":true,
		"direct_message":true,
		"favourite":true,
		"follow_create":true,
		"follow_request":true	
	}
}


200 OK HTTP/1.1
Server: ffapn/1.0
Content-type: application/json

{
	"_id":"1234567890abcdef",
	"udid":"1234567890",
	"user_id":"test",
	"device_token":"000",
	"oauth_token":"111",
	"oauth_secret":"222",
	"consumer_token":"333",
	"consumer_secret":"444",
	"flags": {
		"mention":true,
		"direct_message":true,
		"favourite":true,
		"follow_create":true,
		"follow_request":true	
	}
}

```

---

###DELETE /token/:udid/:user_id

Stop and remve push context
