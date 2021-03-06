# Description:
#   Showing of redmine issuess via the REST API.
#
# Dependencies:
#   None
#
# Configuration:
#   HUBOT_REDMINE_BASE_URL - URL to your Redmine install
#   HUBOT_REDMINE_TOKEN - API key for your selected user
#   HUBOT_REDMINE_SSL - Use "1" if your server uses SSL (https://)
#
# Commands:
#   hubot rm show me <issue-id>     - Show the issue status
#   hubot rm show (my|user's) issues          - Show your issues or another user's issues
#   hubot rm assign <issue-id> to <user-first-name> ["notes"]  - Assign the issue to the user (searches login or firstname)
#   hubot rm update <issue-id> with "<note>"  - Adds a note to the issue
#   hubot rm add <hours> hours to <issue-id> ["comments"]  - Adds hours to the issue with the optional comments
#   hubot rm link me <issue-id> - Returns a link to the redmine issue
#   hubot rm set <issue-id> to <int>% ["comments"] - Updates an issue and sets the percent done
#   hubot rm newissue to "<project>" with "<subject>" - Add a new issue to project with subject

#---
#
# To get set up refer to the guide http://www.redmine.org/projects/redmine/wiki/Rest_api#Authentication
# After that, heroku needs the following config
#
#   heroku config:add HUBOT_REDMINE_BASE_URL="http://redmine.your-server.com"
#   heroku config:add HUBOT_REDMINE_TOKEN="your api token here"
#
# If you are using redmine over HTTPS, add the following config option
#
#   heroku config:add HUBOT_REDMINE_SSL=1
#
# There may be issues if you have a lot of redmine users sharing a first name, but this can be avoided
# by using redmine logins rather than firstnames
#
if process.env.HUBOT_REDMINE_SSL?
  HTTP = require('https')
else
  HTTP = require('http')

URL = require('url')
QUERY = require('querystring')

# function unicodeEscape() is quoted from http://liosk.blog103.fc2.com/blog-entry-67.html
# (modified for coffeescript)
unicodeEscape = (str) ->
    pref = {1: "\\x0", 2: "\\x", 3: "\\u0", 4: "\\u"}
    str.replace(/[^\x00-\x7F]/g, (c) -> pref[(code = c.charCodeAt(0).toString(16)).length] + code )

module.exports = (robot) ->
  redmine = new Redmine process.env.HUBOT_REDMINE_BASE_URL, process.env.HUBOT_REDMINE_TOKEN

  # Robot link me <issue>
  robot.respond /rm link me (?:issue )?(?:#)?(\d+)/i, (msg) ->
    id = msg.match[1]
    msg.send "#{redmine.url}/issues/#{id}"

  # Robot set <issue> to <percent>% ["comments"]
  robot.respond /rm set (?:issue )?(?:#)?(\d+) to (\d{1,3})%?(?: "?([^"]+)"?)?/i, (msg) ->
    [id, percent, notes] = msg.match[1..3]
    percent = parseInt percent

    if notes?
      notes = "#{msg.message.user.name}: #{userComments}"
    else
      notes = "Ratio set by: #{msg.message.user.name}"

    attributes =
      "notes": notes
      "done_ratio": percent

    redmine.Issue(id).update attributes, (err, data, status) ->
      if status == 200
        msg.send "Set ##{id} to #{percent}%"
      else
        msg.send "Update failed! (#{err})"

  # Robot add <hours> hours to <issue_id> ["comments for the time tracking"]
  robot.respond /rm add (\d{1,2}) hours? to (?:issue )?(?:#)?(\d+)(?: "?([^"]+)"?)?/i, (msg) ->
    [hours, id, userComments] = msg.match[1..3]
    hours = parseInt hours

    if userComments?
      comments = "#{msg.message.user.name}: #{userComments}"
    else
      comments = "Time logged by: #{msg.message.user.name}"

    attributes =
      "issue_id": id
      "hours": hours
      "comments": comments

    redmine.TimeEntry(null).create attributes, (error, data, status) ->
      if status == 201
        msg.send "Your time was logged"
      else
        msg.send "Nothing could be logged. Make sure RedMine has a default activity set for time tracking. (Settings -> Enumerations -> Activities)"

  # Robot show <my|user's> [redmine] issues
  robot.respond /rm show (?:my|(\w+\'s)) (?:redmine )?issues/i, (msg) ->
    userMode = true
    firstName =
      if msg.match[1]?
        userMode = false
        msg.match[1].replace(/\'.+/, '')
      else
        msg.message.user.name.split(/\s/)[0]

    redmine.Users name:firstName, (err,data) ->
      unless data.total_count > 0
        msg.send "Couldn't find any users with the name \"#{firstName}\""
        return false

      user = resolveUsers(firstName, data.users)[0]

      params =
        "assigned_to_id": user.id
        "limit": 25,
        "status_id": "open"
        "sort": "priority:desc",

      redmine.Issues params, (err, data) ->
        if err?
          msg.send "Couldn't get a list of issues for you!"
        else
          _ = []

          if userMode
            _.push "You have #{data.total_count} issue(s)."
          else
            _.push "#{user.firstname} has #{data.total_count} issue(s)."

          for issue in data.issues
            do (issue) ->
              _.push "\n[#{issue.tracker.name} - #{issue.priority.name} - #{issue.status.name}] ##{issue.id}: #{issue.subject}"

          msg.send _.join "\n"

  # Robot update <issue> with "<note>"
  robot.respond /rm update (?:issue )?(?:#)?(\d+) (?:\s*with\s*)?"?(.*)"?/i, (msg) ->
    [id, note] = msg.match[1..2]

    attributes =
      "notes": "#{msg.message.user.name}: #{note}"

    redmine.Issue(id).update attributes, (err, data, status) ->
      unless data?
        if status == 404
          msg.send "Issue ##{id} doesn't exist."
        else
          msg.send "Couldn't update this issue, sorry :("
      else
        msg.send "Done! Updated ##{id} with \"#{note}\""

  # Robot newissue to "<project>" with "<subject>"
  robot.respond /rm newissue +(?:\s*to\s*)?"?([A-Za-z0-9_-]*?)"? +(?:\s*with\s*)?"?(.*)"?/i, (msg) ->
    [project_id, subject] = msg.match[1..2]

    attributes =
      'project_id': project_id
      'subject': subject

    redmine.Issue().add attributes, (err, data, status) ->
        unless data?
          if status == 404
            msg.send "Couldn't add this issue, #{status} :("
        else
          console.error(JSON.stringify data)
          msg.send "Done! Added issue #{redmine.url}/issues/#{data.issue.id} with \"#{subject}\""

  # Robot assign <issue> to <user> ["note to add with the assignment]
  robot.respond /rm assign (?:issue )?(?:#)?(\d+) to (\w+)(?: "?([^"]+)"?)?/i, (msg) ->
    [id, userName, note] = msg.match[1..3]

    redmine.Users name:userName, (err, data) ->
      unless data.total_count > 0
        msg.send "Couldn't find any users with the name \"#{userName}\""
        return false

      # try to resolve the user using login/firstname -- take the first result (hacky)
      user = resolveUsers(userName, data.users)[0]

      attributes =
        "assigned_to_id": user.id

      # allow an optional note with the re-assign
      attributes["notes"] = "#{msg.message.user.name}: #{note}" if note?

      # get our issue
      redmine.Issue(id).update attributes, (err, data, status) ->
        unless data?
          if status == 404
            msg.send "Issue ##{id} doesn't exist."
          else
            msg.send "There was an error assigning this issue."
        else
          msg.send "Assigned ##{id} to #{user.firstname}."
          msg.send '/play trombone' if parseInt(id) == 3631

  # Robot show me <issue>
  robot.respond /rm show(?: me)? (?:issue )?(?:#)?(\d+)/i, (msg) ->
    id = msg.match[1]

    params =
      "include": "journals"

    redmine.Issue(id).show params, (err, data, status) ->
      unless status == 200
        msg.send "Issue ##{id} doesn't exist."
        return false

      issue = data.issue

      _ = []
      _.push "\n[#{issue.project.name} - #{issue.priority.name}] #{issue.tracker.name} ##{issue.id} (#{issue.status.name})"
      _.push "Assigned: #{issue.assigned_to?.name ? 'Nobody'} (opened by #{issue.author.name})"
      if issue.status.name.toLowerCase() != 'new'
         _.push "Progress: #{issue.done_ratio}% (#{issue.spent_hours} hours)"
      _.push "Subject: #{issue.subject}"
      _.push "\n#{issue.description}"

      # journals
      _.push "\n" + Array(10).join('-') + '8<' + Array(50).join('-') + "\n"
      for journal in issue.journals
        do (journal) ->
          if journal.notes? and journal.notes != ""
            date = formatDate journal.created_on, 'mm/dd/yyyy (hh:ii ap)'
            _.push "#{journal.user.name} on #{date}:"
            _.push "    #{journal.notes}\n"

      msg.send _.join "\n"

# simple ghetto fab date formatter this should definitely be replaced, but didn't want to
# introduce dependencies this early
#
# dateStamp - any string that can initialize a date
# fmt - format string that may use the following elements
#       mm - month
#       dd - day
#       yyyy - full year
#       hh - hours
#       ii - minutes
#       ss - seconds
#       ap - am / pm
#
# returns the formatted date
formatDate = (dateStamp, fmt = 'mm/dd/yyyy at hh:ii ap') ->
  d = new Date(dateStamp)

  # split up the date
  [m,d,y,h,i,s,ap] =
    [d.getMonth() + 1, d.getDate(), d.getFullYear(), d.getHours(), d.getMinutes(), d.getSeconds(), 'AM']

  # leadig 0s
  i = "0#{i}" if i < 10
  s = "0#{s}" if s < 10

  # adjust hours
  if h > 12
    h = h - 12
    ap = "PM"

  # ghetto fab!
  fmt
    .replace(/mm/, m)
    .replace(/dd/, d)
    .replace(/yyyy/, y)
    .replace(/hh/, h)
    .replace(/ii/, i)
    .replace(/ss/, s)
    .replace(/ap/, ap)

# tries to resolve ambiguous users by matching login or firstname
# redmine's user search is pretty broad (using login/name/email/etc.) so
# we're trying to just pull it in a bit and get a single user
#
# name - this should be the name you're trying to match
# data - this is the array of users from redmine
#
# returns an array with a single user, or the original array if nothing matched
resolveUsers = (name, data) ->
    name = name.toLowerCase();

    # try matching login
    found = data.filter (user) -> user.login.toLowerCase() == name
    return found if found.length == 1

    # try first name
    found = data.filter (user) -> user.firstname.toLowerCase() == name
    return found if found.length == 1

    # give up
    data

# Redmine API Mapping
# This isn't 100% complete, but its the basics for what we would need in campfire
class Redmine
  constructor: (url, token) ->
    @url = url
    @token = token

  Users: (params, callback) ->
    @get "/users.json", params, callback

  User: (id) ->

    show: (callback) =>
      @get "/users/#{id}.json", {}, callback

  Projects: (params, callback) ->
    @get "/projects.json", params, callback

  Issues: (params, callback) ->
    @get "/issues.json", params, callback

  Issue: (id) ->

    show: (params, callback) =>
      @get "/issues/#{id}.json", params, callback

    update: (attributes, callback) =>
      @put "/issues/#{id}.json", {issue: attributes}, callback

    add: (attributes, callback) =>
      @post "/issues.json", {issue: attributes}, callback

  TimeEntry: (id = null) ->

    create: (attributes, callback) =>
      @post "/time_entries.json", {time_entry: attributes}, callback

  # Private: do a GET request against the API
  get: (path, params, callback) ->
    path = "#{path}?#{QUERY.stringify params}" if params?
    @request "GET", path, null, callback

  # Private: do a POST request against the API
  post: (path, body, callback) ->
    @request "POST", path, body, callback

  # Private: do a PUT request against the API
  put: (path, body, callback) ->
    @request "PUT", path, body, callback

  # Private: Perform a request against the redmine REST API
  # from the campfire adapter :)
  request: (method, path, body, callback) ->
    headers =
      "Content-Type": "application/json"
      "X-Redmine-API-Key": @token

    endpoint = URL.parse(@url)
    pathname = endpoint.pathname.replace /^\/$/, ''

    options =
      "host"   : endpoint.hostname
      "port"   : endpoint.port
      "path"   : "#{pathname}#{path}"
      "method" : method
      "headers": headers

    if method in ["POST", "PUT"]
      if typeof(body) isnt "string"
        body = JSON.stringify body
        # JSON.stringify does not encode Japanese characters, but Redmine API
        # does not accept raw Japanese characters. So escape non-ASCII characters unicodeEscape function.
        body = unicodeEscape body

      options.headers["Content-Length"] = body.length

    request = HTTP.request options, (response) ->
      data = ""

      response.on "data", (chunk) ->
        data += chunk

      response.on "end", ->
        switch response.statusCode
          when 200,201
            try
              callback null, JSON.parse(data), response.statusCode
            catch err
              callback null, (data or { }), response.statusCode
          when 401
            throw new Error "401: Authentication failed."
          else
            console.error "Code: #{response.statusCode}"
            callback null, null, response.statusCode

      response.on "error", (err) ->
        console.error "Redmine response error: #{err}"
        callback err, null, response.statusCode

    if method in ["POST", "PUT"]
      request.end(body, 'binary')
    else
      request.end()

    request.on "error", (err) ->
      console.error "Redmine request error: #{err}"
      callback err, null, 0
