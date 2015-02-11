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
#   hubot phabricator subscribe - Subscribes to important actions (**use only in DM**)
#   hubot phabricator unsubscribe - Unsubscribes from important actions

_ = require 'lodash'
sha1 = require 'sha1'

{
  HUBOT_PHABRICATOR_HOST: PH_HOST # "http://example.com"
  HUBOT_PHABRICATOR_USER: PH_USER # "username on phabricator"
  HUBOT_PHABRICATOR_CERT: PH_CERT # "certificate from [PH_HOST]/settings/panel/conduit/"
} = process.env

keyPHId = (userId) -> 'pha__phid_'+userId
keySubInterval = (userId) -> 'pha__sub_interval_'+userId
keySubLast = (userId) -> 'pha__sub_last_'+userId

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
        if bodyJSON.result?
          callback bodyJSON.result
        else
          console.dir bodyJSON
          callback null, 'error with conduit call: '+bodyJSON.error_code


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
        if bodyJSON.result?
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
          callback null, 'error with signature conduit call: '+bodyJSON.error_code

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
          replyToAnon msg

  robot.respond /pha(bricator)? i('m| am) ([a-z0-9]+)/i, (msg) ->
    userId = msg.message.user.id
    replyWithPHID(robot, userId, msg.match[3]) (phid) ->
      if phid?
        robot.brain.set keyPHId(userId), phid
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

  robot.respond /pha(bricator)? unsub(scribe)?/i, (msg) ->
    userId = msg.message.user.id

    if msg.getChannelType?() == 'DM'
      msg.reply 'deal with subscription in private'

    if robot.brain.get keySubInterval userId
      clearInterval robot.brain.get keySubInterval userId

    robot.brain.remove keySubInterval userId
    robot.brain.remove keySubLast userId

    msg.reply 'you\'ve been unsubscribed from phabricator notifications'

  robot.respond /pha(bricator)? sub(scribe)?/i, (msg) ->
    userId = msg.message.user.id

    if msg.getChannelType?() == 'DM'
      msg.reply 'subscribe in private'
      return

    if robot.brain.get keySubInterval userId
      clearInterval robot.brain.get keySubInterval userId
      robot.brain.remove keySubInterval userId

    replyWithPHID(robot, userId) (phid) ->
      unless phid?
        replyToAnon msg
        return

      responsibleUsers = [phid]
      limit = 10
      query = _.assign {responsibleUsers, limit}, {
        order: 'order-modified'
      }

      intervalId = setInterval(
        ->
          performConduitCall(robot, 'differential.query', query) (result, err) ->
            if err
              msg.reply err
              return

            if robot.brain.get keySubLast userId
              lastChecked = robot.brain.get keySubLast userId
              result = _.filter(
                result,
                (value) ->
                  value.dateModified >= lastChecked
              )

            robot.brain.set keySubLast(userId), parseInt(Date.now() / 1000, 10)

            result = _.filter(
              result,
              (value) ->
                switch value.status
                  when '0' # Needs review
                    phid in value.reviewers
                  when '1' # Needs revision
                    phid is value.author
                  when '2' # Accepted
                    phid is value.author
                  when '3' # Closed
                    false
                  when '4' # Abandoned
                    false
            )

            unless result.length
              return

            diffsList = _.map(result, (value) ->
              switch value.status
                when '0' # Needs review
                  icon = ':o:'
                when '1' # Needs revision
                  icon = ':-1:'
                when '2' # Accepted
                  icon = ':+1:'
                when '3' # Closed
                  icon = ':shipit:'
                when '4' # Abandoned
                  icon = ':poop:'

              {
                text: (
                  "#{icon} #{value.uri}\n\t#{value.title}"
                    .replace('&', '&amp;')
                    .replace('<', '&lt;')
                    .replace('>', '&gt;')
                )
              }
            )

            msg.reply(
              _.pluck(
                diffsList
                'text'
              ).join('\n\t')
            )
        30000
      )

      robot.brain.setet keySubInterval(userId), intervalId

      msg.reply 'you\'ve been subscribed to phabricator notifications'
