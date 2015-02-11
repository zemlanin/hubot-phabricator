# hubot-phabricator

A Hubot script for interacting with Phabricator

## commands
```
phabricator ping
phabricator whoami
phabricator i am $USERNAME
phabricator update signature
[phabricator] my reviews
phabricator subscribe
phabricator unsubscribe
```

## TODO
- [x] hubot script documentation 
- [ ] **TESTS**
- [ ] reviews of other users
- [x] notify user on new reviews
  - [x] _optionally_ notify user on new reviews
- [ ] guess phabricator username not only by email, but also by chat username
- [ ] slack attachments (slackhq/hubot-slack#148)
- [ ] reply with differential link on messages with D[0-9]+
