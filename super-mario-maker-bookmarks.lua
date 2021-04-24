dofile("table_show.lua")
dofile("urlcode.lua")
dofile("strict.lua")
local urlparse = require("socket.url")
local luasocket = require("socket") -- Used to get sub-second time
local http = require("socket.http")
JSON = assert(loadfile "JSON.lua")()

local item_name_newline = os.getenv("item_name_newline")
local item_dir = os.getenv('item_dir')
local warc_file_base = os.getenv('warc_file_base')

local url_count = 0
local tries = 0
local downloaded = {}
local addedtolist = {}
local abortgrab = false


discovered_items = {}
local last_main_site_time = 0

if urlparse == nil or http == nil then
  io.stdout:write("socket not corrently installed.\n")
  io.stdout:flush()
  abortgrab = true
end

graph_out_file = io.open("graph_lua.dot", "w+")
graph_out_file:write("digraph {")
function wtg(src, dest)
  if src == nil then
    src = "Nil"
  end
  if dest == nil then
    dest = "Nil"
  end
  graph_out_file:write('"' .. src .. '" -> "' .. dest .. '";}')
  graph_out_file:seek("cur", -1)
  graph_out_file:flush()
end

for ignore in io.open("ignore-list", "r"):lines() do
  downloaded[ignore] = true
  if string.match(ignore, '^https:') then
    downloaded[string.gsub(ignore, '^https', 'http', 1)] = true
  elseif string.match(ignore, '^http:') then
    downloaded[string.gsub(ignore, '^http:', 'https:', 1)] = true
  end
end

read_file = function(file)
  if file then
    local f = assert(io.open(file))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

io.stdout:setvbuf("no") -- So prints are not buffered - http://lua.2524044.n2.nabble.com/print-stdout-and-flush-td6406981.html

p_assert = function(v)
  if not v then
    print("Assertion failed - aborting item")
    print(debug.traceback())
    abortgrab = true
  end
end

do_debug = true
print_debug = function(a)
    if do_debug then
        print(a)
    end
end
print_debug("The grab script is running in debug mode. You should not see this in production.")

function is_on_targeted(url)
  return string.match(url, "^https?://[^/]+%.aimix%-z%.com") ~= nil
end

allowed = function(url, parenturl)
  assert(parenturl ~= nil)
  -- Backfeed different forums and reject
  local function find_room(url)
    if url == nil or not is_on_targeted(url) then
      return nil
    end
    local match = string.match(url, "%?room=([%w%-%_]+)")
    if not match then
      match = string.match(url, "&room=([%w%-%_]+)")
    end
    return match
  end
  local this_room = find_room(url)
  local parent_room = find_room(parenturl)
  if this_room ~= nil and parent_room ~= nil and this_room ~= parent_room then
    -- TODO queue as multiiem
    print("Would have queued " .. this_room .. " from " .. parent_room)
    return false
  end

  -- Reject social media share buttons
  if string.match(url, "^https?://twitter%.com/intent/")
    or string.match(url, "^https?://platform%.twitter%.com/")
    or string.match(url, "^https?://b%.hatena%.ne%.jp/entry/")
    or string.match(url, "^https?://www%.facebook%.com/plugins/like%.php") then
    return false
  end

  -- Ads
  if string.match(url, "^https?://[^/]+%.valuecommerce%.com/") then
    return false
  end



  -- Reject new/edit/delete/admin-action/reply pages
  if string.match(url, "^https?://[^/]+%.aimix%-z%.com/mtptwrite%.cgi")
      or string.match(url, "^https?://[^/]+%.aimix%-z%.com/mtpt%.cgi.*&quo=[0-9]+")-- Reply (GT: "quote")
      or string.match(url, "^https?://[^/]+%.aimix%-z%.com/mtpt%.cgi.*&mode=form")
      or string.match(url, "^https?://[^/]+%.aimix%-z%.com/mtpt%.cgi.*&mode=admin")
      or string.match(url, "^https?://[^/]+%.aimix%-z%.com/mtptwrite%.cgi.*&mode=mente") -- Edit/delete post
    -- gbbs
      or string.match(url, "^https?://[^/]+%.aimix%-z%.com/gbbs%.cgi.*&mode=enter") -- Admin
      or string.match(url, "^https?://[^/]+%.aimix%-z%.com/gbbs%.cgi.*&mode=uedit")
      or string.match(url, "^https?://[^/]+%.aimix%-z%.com/gbbs%.cgi.*&mode=howto&page=") -- This will break some links, but
    -- won't really ignore any information (the "page" parameter is so that a "Back" button can work)

  then
    return false
  end

  -- Board not found error
  if string.match(url, "https?://[^/]+%.aimix%-z%.com/error0015%.html") then
    return false
  end

  -- Misc
  if string.match(url, "^https?://[^/]+%.aimix%-z%.com/view%-source:")
  or string.match(url, "^https?://[^/]+%.aimix%-z%.com/counter%.cgi")
  or string.match(url, "^https?://[^/]+%.aimix%-z%.com/docs/")
  or string.match(url, "^https?://purl%.org/")
  or string.match(url, "^https?://www%.w3%.org/")
  or string.match(url, "rdf:resource=") -- As usual, garbage extracted from somewhere
  or string.match(url, "rdf:about=")
  then
    return false
  end


  local tested = {}
  for s in string.gmatch(url, "([^/]+)") do
    if tested[s] == nil then
      tested[s] = 0
    end
    if tested[s] == 6 then
      return false
    end
    tested[s] = tested[s] + 1
  end

  -- Accept directly-linked external URLs; external links from external links
  if not is_on_targeted(url) then
    --print_debug("Not IOT " .. url .. " " .. parenturl)
    return (parenturl ~= nil) and (is_on_targeted(parenturl) ~= false)
  end

  --print_debug("Allowed true " .. url .. " " .. parenturl)
  return true
end


wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  local url = urlpos["url"]["url"]
  if downloaded[url] == true or addedtolist[url] == true then
    return false
  end
  if allowed(url, parent["url"]) then
    addedtolist[url] = true
    wtg(parent["url"], url)
    return true
  end

  return false
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil

  downloaded[url] = true

  local function check(urla, force)
    p_assert((not force) or (force == true)) -- Don't accidentally put something else for force
    local origurl = url
    local url = string.match(urla, "^([^#]+)")
    local url_ = string.match(url, "^(.-)%.?$")
    url_ = string.gsub(url_, "&amp;", "&")
    url_ = string.match(url_, "^(.-)%s*$")
    url_ = string.match(url_, "^(.-)%??$")
    url_ = string.match(url_, "^(.-)&?$")
    url_ = string.match(url_, "^(.-)/?$")
    if (downloaded[url_] ~= true and addedtolist[url_] ~= true)
      and (allowed(url_, origurl) or force) then
      table.insert(urls, { url=url_ })
      addedtolist[url_] = true
      addedtolist[url] = true
    end
  end

  local function checknewurl(newurl)
    if string.match(newurl, "\\[uU]002[fF]") then
      return checknewurl(string.gsub(newurl, "\\[uU]002[fF]", "/"))
    end
    if string.match(newurl, "^https?:////") then
      check((string.gsub(newurl, ":////", "://")))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check((string.gsub(newurl, "\\", "")))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^%${")) then
      check(urlparse.absolute(url, "/" .. newurl))
    end
  end
  
  local function load_html()
    if html == nil then
      html = read_file(file)
    end
  end

  

  if status_code == 200 and not (string.match(url, "jpe?g$") or string.match(url, "png$")) then
    load_html()
    for newurl in string.gmatch(string.gsub(html, "&quot;", '"'), '([^"]+)') do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
      checknewurl(newurl)
    end
    for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
      checknewshorturl(newurl)
    end
    for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
      checknewurl(newurl)
    end
  end

  for _, nurl in pairs(urls) do
    wtg(url, nurl["url"])
  end
  return urls
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. "  \n")
  io.stdout:flush()
  print_debug(err)


  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if downloaded[newloc] == true or addedtolist[newloc] == true
            or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  if status_code >= 200 and status_code <= 399 then
    downloaded[url["url"]] = true
  end

  if abortgrab == true then
    io.stdout:write("ABORTING...\n")
    io.stdout:flush()
    return wget.actions.ABORT
  end

  --

  
  local do_retry = false
  local maxtries = 12
  local url_is_essential = false

  -- Whitelist instead of blacklist status codes
  if status_code ~= 200 and status_code ~= 404 and not (status_code >= 300 and status_code <= 399) then
    io.stdout:write("Server returned " .. http_stat.statcode .. " (" .. err .. "). Sleeping.\n")
    io.stdout:flush()
    do_retry = true
  end

  if is_on_targeted(url["url"]) then
    -- Sleep for up to 2s average
    local now_t = luasocket.gettime()
    local makeup_time = 10 - (now_t - last_main_site_time)
    if makeup_time > 0 then
      makeup_time = makeup_time + math.random() * 3
      print_debug("Sleeping for main site " .. makeup_time)
      os.execute("sleep " .. makeup_time)
    end
    last_main_site_time = now_t
  end

  -- Essential URLs are on site
  if is_on_targeted(url["url"]) then
    url_is_essential = true
    maxtries = 12
  else
    url_is_essential = false
    maxtries = 4
  end


  if do_retry then
    if tries >= maxtries then
      io.stdout:write("I give up...\n")
      io.stdout:flush()
      tries = 0
      if not url_is_essential then
        return wget.actions.EXIT
      else
        print("Failed on an essential URL, aborting...")
        return wget.actions.ABORT
      end
    else
      sleep_time = math.floor(math.pow(2, tries))
      tries = tries + 1
    end
  end


  if do_retry and sleep_time > 0.001 then
    print("Sleeping " .. sleep_time .. "s")
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  end

  tries = 0
  return wget.actions.NOTHING
end


wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  if do_debug then
    for item, _ in pairs(discovered_items) do
      print("Would have sent discovered item " .. item)
    end
  else
    to_send = nil
    for item, _ in pairs(discovered_items) do
      if to_send == nil then
        to_send = url
      else
        to_send = to_send .. "\0" .. item
      end
    end

    if to_send ~= nil then
      local tries = 0
      while tries < 10 do
        local body, code, headers, status = http.request(
          --"http://blackbird.arpa.li:23038/whatever/" -- New address - #noanswers 2021-04-20Z
                "http://example.com",
          to_send
        )
        if code == 200 or code == 409 then
          break
        end
        os.execute("sleep " .. math.floor(math.pow(2, tries)))
        tries = tries + 1
      end
      if tries == 10 then
        abortgrab = true
      end
    end
  end
end


wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if abortgrab == true then
    return wget.exits.IO_FAIL
  end
  return exit_status
end

