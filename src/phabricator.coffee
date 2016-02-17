# Description:
#   A Hubot script for interacting with Phabricator
#
# Dependencies:
#   "lodash": "^3.1.0"
#   "sha1": "^1.1.0"
#
# Configurations:
#   HUBOT_PHABRICATOR_HOST="http://example.com"
#   HUBOT_PHABRICATOR_USER="usernameOnPhabricator"
#   HUBOT_PHABRICATOR_CERT="certificateFrom[HUBOT_PHABRICATOR_HOST]/settings/panel/conduit/"
#
# Commands:
#   hubot phabricator my <any|open|closed|accepted> reviews - Displays reviews which has you as responsible user
#   hubot my reviews - Alias for `phabricator my reviews`
#   hubot phabricator whoami - Displays your linked Phabricator username guessed based on email
#   hubot phabricator i am <username> - Sets your linked Phabricator username
#   hubot phabricator ping - Pings Phabricator's API  
#   hubot phabricator update signature - Updates session key and connection in Hubot's brain
#   phabricator subscribe - Subscribes to important actions (**use only in DM**)
#   phabricator unsubscribe - Unsubscribes from important actions (**use only in DM**)

_ = require 'lodash'
sha1 = require 'sha1'

{
  HUBOT_PHABRICATOR_HOST: PH_HOST # "http://example.com"
  HUBOT_PHABRICATOR_USER: PH_USER # "username on phabricator"
  HUBOT_PHABRICATOR_CERT: PH_CERT # "certificate from [PH_HOST]/settings/panel/conduit/"
  HUBOT_PHABRICATOR_DEBUG_ROOM: DEBUG_ROOM # room to send debugging information to
} = process.env

if not DEBUG_ROOM
  DEBUG_ROOM = "general"

keyPHId = (userId) -> 'pha__phid_'+userId
keyUser = (phid) -> 'pha__user_'+phid
keySubIgnore = 'pha__sub_ignore'
keySubLast = 'pha__sub_last'

STATUS =
  NEEDS_REVIEW: '0'
  NEEDS_REVISION: '1'
  ACCEPTED: '2'
  CLOSED: '3'
  ABANDONED: '4'

modifiedAfter = (lastChecked, value) ->
  value.dateModified >= lastChecked

_performSignedConduitCall = (robot, endpoint, signature, params) ->
  return (callback) -> # callback :: (result, err) ->
    params['__conduit__'] = signature

    data = [
      'params='+JSON.stringify params
      'output=json'
    ].join '&'

    robot.http(PH_HOST + '/api/' + endpoint, {
      headers: {'Content-Type': 'application/x-www-form-urlencoded'}
    })
      .post(data) (err, res, body) ->
        bodyJSON = JSON.parse body
        if bodyJSON?.result
          callback bodyJSON.result
        else if bodyJSON?.error_code is 'ERR-INVALID-SESSION'
          getConduitSignature robot, (->)
        else
          callback null, 'error with conduit call: '+bodyJSON?.error_code


performConduitCall = (robot, endpoint, params={}) ->
  signature = {
    sessionKey: robot.brain.get 'conduit__signature_sessionKey'
    connectionID: robot.brain.get 'conduit__signature_connectionID'
  }

  if signature.sessionKey? and signature.connectionID?
    return _performSignedConduitCall robot, endpoint, signature, params
  else
    return getConduitSignature robot, (signature) ->
      _performSignedConduitCall robot, endpoint, signature, params

getConduitSignature = (robot, signCallback) ->
  (callback) -> # callback :: (result, err) ->
    token = parseInt(Date.now()/1000, 10)

    params = JSON.stringify {
      client: 'hubot'
      host: PH_HOST
      user: PH_USER
      authToken: token.toString()
      authSignature: sha1(token.toString() + PH_CERT)
    }

    data = [
      'params='+params
      '__conduit__=true'
      'output=json'
    ].join '&'

    robot.http(PH_HOST + '/api/conduit.connect', {
      headers: {'Content-Type': 'application/x-www-form-urlencoded'}
    })
      .post(data) (err, res, body) ->
        bodyJSON = JSON.parse body
        if bodyJSON?.result?
          robot.brain.set {
            'conduit__signature_sessionKey': bodyJSON.result.sessionKey
            'conduit__signature_connectionID': bodyJSON.result.connectionID
          }

          return signCallback({
            sessionKey: bodyJSON.result.sessionKey
            connectionID: bodyJSON.result.connectionID
          })(callback)
        else
          console.dir bodyJSON
          callback null, 'error with signature conduit call: '+bodyJSON?.error_code

replyWithPHID = (robot, userId, possibleUsername) ->
  phid = robot.brain.get keyPHId(userId)

  if phid? and not possibleUsername?
    (callback) -> callback phid
  else
    (callback) ->
      aliases = if possibleUsername?
        [possibleUsername]
      else
        user = robot.brain.userForId userId
        [
          user.email_address.replace(/@.*/i, '').replace(/\./i, '')
        ]

      performConduitCall(robot, 'user.find', {aliases}) (result, err) ->
        if result?[aliases[0]]?
          unless possibleUsername
            robot.brain.set keyPHId(userId), result[aliases[0]]
            robot.brain.set keyUser(result[aliases[0]]), userId

          callback result[aliases[0]]
        else
          callback null

replyToAnon = (msg) ->
  msg.reply 'phabricator doesn\'t know you'
  msg.reply 'try specifing your name by "phabricator i am [NAME]" command'


module.exports = (robot) ->
  return robot.logger.error "config hubot-phabricator script" unless PH_HOST and PH_USER and PH_CERT

  robot.respond /pha(bricator)? whoami/i, (msg) ->
    userId = msg.message.user.id
    replyWithPHID(robot, userId) (phid) ->
      unless phid?
        replyToAnon msg
        return

      names = [phid]

      performConduitCall(robot, 'phid.lookup', {names}) (result, err) ->
        if err
          msg.reply err
          return

        if result[phid]?
          msg.reply 'you are ' + result[phid].name
        else
          robot.brain.remove keyPHId(userId)
          robot.brain.remove keyUser(phid)
          replyToAnon msg

  robot.respond /pha(bricator)? i('m| am) ([a-zA-Z0-9._-]+)/i, (msg) ->
    userId = msg.message.user.id
    replyWithPHID(robot, userId, msg.match[3]) (phid) ->
      if phid?
        robot.brain.set keyPHId(userId), phid
        robot.brain.set keyUser(phid), userId
        msg.reply 'i will remember your phid, which is ' + phid

      else
        msg.reply 'phabricator doesn\'t know this name'

  robot.respond /pha(bricator)? ping/i, (msg) ->
    performConduitCall(robot, 'conduit.ping') (result, err) ->
      if err
        msg.reply err
        return

      msg.reply result

  robot.respond /pha(bricator)? update signature/i, (msg) ->
    getConduitSignature(robot, -> (->) ) (signature, err) ->
      if err
        msg.reply err
      else
        msg.reply 'signature ok'

  robot.respond /(pha |phabricator)? ?my (any|open|closed|accepted)? ?reviews/i, (msg) ->
    userId = msg.message.user.id

    replyWithPHID(robot, userId) (phid) ->
      unless phid?
        replyToAnon msg
        return

      statusName = msg.match[2] or 'open'

      status = 'status-' + statusName
      responsibleUsers = [phid]
      query = _.assign {status, responsibleUsers}, {
        order: 'order-modified'
      }

      performConduitCall(robot, 'differential.query', query) (result, err) ->
        if err
          msg.reply err
          return

        diffsList = _.map(result, (value) ->
          important = false
          switch value.status
            when '0' # Needs review
              icon = ':o:'
              important = phid in value.reviewers
            when '1' # Needs revision
              icon = ':-1:'
              important = phid is value.author
            when '2' # Accepted
              icon = ':+1:'
              important = phid is value.author
            when '3' # Closed
              icon = ':shipit:'
            when '4' # Abandoned
              icon = ':poop:'

          {
            waitingForOthers: not important
            text:(
              "#{icon} #{value.uri}\n\t#{if important then ':bangbang: ' else ''}#{value.title}"
                .replace('&', '&amp;')
                .replace('<', '&lt;')
                .replace('>', '&gt;')
            )
          }
        )

        msg.reply(
          'you have ' + _.keys(result).length + ' ' + statusName + ' reviews\n\t' +
          _.pluck(
            _.sortBy(diffsList, 'waitingForOthers')
            'text'
          ).join('\n\t')
        )

  subIntervalId = setInterval(
    ->
      query = {
        order: 'order-modified'
        limit: 10
      }

      performConduitCall(robot, 'differential.query', query) (result, err) ->
        if err
          robot.messageRoom DEBUG_ROOM, 'phabricator subscription error: '+err
          clearInterval subIntervalId
          return

        if robot.brain.get keySubLast
          lastChecked = robot.brain.get keySubLast
          result = _.filter(
            result,
            modifiedAfter.bind null, lastChecked
          )

        robot.brain.set keySubLast, parseInt(Date.now() / 1000, 10)

        unless result.length
          return

        for review in result
          icon = switch review.status
            when STATUS.NEEDS_REVIEW
              ':o:'
            when STATUS.NEEDS_REVISION
              ':-1:'
            when STATUS.ACCEPTED
              ':+1:'
            when STATUS.CLOSED
              ':shipit:'
            when STATUS.ABANDONED
              ':poop:'

          notifyUsers = switch review.status
            when STATUS.NEEDS_REVIEW
              _(review.reviewers)
            when STATUS.NEEDS_REVISION
              _([review.authorPHID])
            when STATUS.ACCEPTED
              _([review.authorPHID])
            when STATUS.CLOSED
              _()
            when STATUS.ABANDONED
              _()

          notifyUsers
            .reject(_.includes.bind(null, robot.brain.get keySubIgnore))
            .map(keyUser)
            .map(robot.brain.get.bind(robot.brain))
            .filter()
            .map(robot.brain.userForId.bind(robot.brain))
            .filter()
            .map('name')
            .each(
              (username) ->
                msgText = (
                  "#{icon} #{review.uri}\n\t#{review.title}"
                    .replace('&', '&amp;')
                    .replace('<', '&lt;')
                    .replace('>', '&gt;')
                )
                robot.messageRoom username, msgText
            )
            .value()
    30000
  )

  robot.respond /pha(bricator)? unsub(scribe)?/i, (msg) ->
    userId = msg.message.user.id

    if msg.message.room != msg.message.user.name
      msg.reply 'deal with subscription in private'

    replyWithPHID(robot, userId) (phid) ->
      unless phid?
        replyToAnon msg
        return

      ignoreList = robot.brain.get(keySubIgnore) or []
      if phid in ignoreList
        msg.reply 'you\'ve already been unsubscribed from phabricator notifications'
      else
        ignoreList.push phid
        robot.brain.set keySubIgnore, ignoreList

        msg.reply 'you\'ve been unsubscribed from phabricator notifications'

  robot.respond /pha(bricator)? sub(scribe)?/i, (msg) ->
    userId = msg.message.user.id

    if msg.message.room != msg.message.user.name
      msg.reply 'deal with subscription in private'

    replyWithPHID(robot, userId) (phid) ->
      unless phid?
        replyToAnon msg
        return

      ignoreList = robot.brain.get(keySubIgnore) or []
      if phid in ignoreList
        ignoreList = _.without ignoreList, phid
        robot.brain.set keySubIgnore, ignoreList

      msg.reply 'you\'ve been subscribed to phabricator notifications'
