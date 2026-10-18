-- Lionfell client updater. On start, before the other modules load, the client fetches the
-- release manifest from the update server (Services.updater, set in init.lua) and downloads every
-- file whose checksum differs from the file on disk, then restarts into the new version.
--
-- Server side: tools/lionfell_release.py builds a release (manifest.json + files/) from the client
-- folder and tools/lionfell_update_server.py serves it. Manifest:
--   { version = "...", url = "files/", files = { ["modules/x/x.lua"] = "<crc32 hex>", ... },
--     binary = { file = "otclient", checksum = "<crc32 hex>" },
--     binary_windows = { file = "otclient.exe", checksum = "<crc32 hex>" } }
-- Paths are real paths inside the client folder. A new client program is saved as <file>.new and
-- swapped in by the launcher (lionfell.sh, or lionfell.bat on Windows) when the client restarts.
--
-- The updater never blocks play: if the server can't be reached or a download fails, the client
-- starts with the files it has.

Updater = {}

Updater.maxRetries = 3
Updater.checkTimeout = 8000 -- ms to wait for the manifest

local updaterWindow
local loadModulesFunction
local scheduledEvent
local httpOperationId = 0
local finished = false
local sessionCallback = nil -- set by Updater.checkDuringSession

local function baseUrl()
  local url = Services.updater or ""
  if url:sub(-1) ~= "/" then
    url = url .. "/"
  end
  return url
end

-- thin Lionfell bar (client_lionfell LfBar): the fill child is sized to the percentage
local ACCENT = '#c8a24a'
local function setBar(bar, percent)
    if not bar or not bar.fill then
        return
    end
    percent = math.max(0, math.min(100, percent))
    bar.fill:setBackgroundColor(ACCENT)
    bar.fill:setWidth(math.floor(bar:getWidth() * percent / 100))
    if bar == updaterWindow.mainProgress then
        updaterWindow.percent:setText(percent .. '%')
    end
end

local function setStatus(text)
  if updaterWindow then
    updaterWindow.status:setText(text)
  end
end

local function localChecksum(path)
  local ok, contents = pcall(g_resources.readFileContentsFromWorkDir, path)
  if not ok or not contents then
    return nil
  end
  return g_crypt.crc32(contents, false)
end

local function finish()
  if finished then return end
  finished = true
  if httpOperationId then
    HTTP.cancel(httpOperationId)
    httpOperationId = nil
  end
  removeEvent(scheduledEvent)
  if updaterWindow then
    updaterWindow:destroy()
    updaterWindow = nil
  end
  if loadModulesFunction then
    local load = loadModulesFunction
    loadModulesFunction = nil
    load()
  end
  -- a check during a session (server update) reports back to its caller only: the startup
  -- listeners of onUpdateFinished (game interface, client) must not run a second time
  if sessionCallback then
    local callback = sessionCallback
    sessionCallback = nil
    callback()
    return
  end
  signalcall(g_app.onUpdateFinished, g_app)
end

-- start again through the launcher, which swaps in a downloaded binary
local function restart()
  local workDir = g_resources.getWorkDir()
  local started = false
  if g_app.getOs() == "windows" then
    if g_resources.fileExistsInWorkDir("lionfell.bat") then
      local cmd = os.getenv("COMSPEC") or "C:\\Windows\\System32\\cmd.exe"
      started = g_platform.spawnProcess(cmd, { "/c", workDir .. "lionfell.bat", "--updated" })
    end
  elseif g_resources.fileExistsInWorkDir("lionfell.sh") then
    -- the client starts again with the options it was started with (e.g. --user-dir)
    local args = { workDir .. "lionfell.sh", "--updated" }
    for option in (g_app.getStartupOptions() or ""):gmatch("%S+") do
      table.insert(args, option)
    end
    started = g_platform.spawnProcess("/bin/sh", args)
  end
  if started then
    g_app.exit()
  else
    g_app.restart()
  end
end

local function install(toUpdate, version)
  setStatus(tr("Installing update"))
  local failed = {}
  for _, entry in ipairs(toUpdate) do
    local target = entry.binary and (entry.path .. ".new") or entry.path
    if not g_resources.writeDownloadedFileToWorkDir(entry.path, target, false) then
      table.insert(failed, entry.path)
    end
  end
  if #failed > 0 then
    -- files that were written stay; the next start retries the rest
    g_logger.error("Lionfell update: could not write " .. table.concat(failed, ", "))
  end
  g_logger.info(("Lionfell update %s installed (%d files), restarting"):format(version, #toUpdate - #failed))
  scheduledEvent = scheduleEvent(restart, 200)
end

local function downloadFiles(url, toUpdate, index, retries, version)
  if finished then return end
  local entry = toUpdate[index]
  if not entry then
    return install(toUpdate, version)
  end
  if updaterWindow then
    updaterWindow.downloadStatus:setText(('%d / %d  \183  %s'):format(index, #toUpdate, entry.path:match('[^/]+$') or entry.path))
    setBar(updaterWindow.downloadProgress, 0)
    setBar(updaterWindow.mainProgress, math.floor(100 * (index - 1) / #toUpdate))
  end

  httpOperationId = HTTP.download(url .. entry.path, entry.path,
    function(file, checksum, err)
      if finished then return end
      if not err and checksum ~= entry.checksum then
        err = ("checksum %s, expected %s"):format(tostring(checksum), entry.checksum)
      end
      if err then
        if retries >= Updater.maxRetries then
          g_logger.warning(("Lionfell update: %s failed (%s)"):format(entry.path, tostring(err)))
          return Updater.fail(tr("Could not download %s.", entry.path))
        end
        scheduledEvent = scheduleEvent(function()
          downloadFiles(url, toUpdate, index, retries + 1, version)
        end, 500)
        return
      end
      downloadFiles(url, toUpdate, index + 1, 0, version)
    end,
    function(progress, speed)
      if updaterWindow then
        setBar(updaterWindow.downloadProgress, progress)
      end
    end)
end

local function onManifest(data)
  if type(data) ~= "table" or type(data.files) ~= "table" then
    return Updater.fail(tr("The update server sent an invalid release."))
  end
  local url = data.url or "files/"
  if not url:find("^https?://") then
    url = baseUrl() .. url
  end
  local version = tostring(data.version or "?")

  setStatus(tr("Checking files"))
  local toUpdate = {}
  for path, checksum in pairs(data.files) do
    -- release paths are plain relative paths; anything else is ignored
    if type(path) == "string" and not path:find("%.%.") and path:sub(1, 1) ~= "/" and
        localChecksum(path) ~= checksum then
      table.insert(toUpdate, { path = path, checksum = checksum })
    end
  end
  table.sort(toUpdate, function(a, b) return a.path < b.path end)

  -- the client program for this system: "binary" (Linux) or "binary_windows"
  local system = g_app.getOs()
  local binary = (system == "linux" and data.binary) or (system == "windows" and data.binary_windows) or nil
  if type(binary) == "table" and type(binary.file) == "string" then
    local current = g_resources.selfChecksum()
    if current ~= "" and current ~= binary.checksum and localChecksum(binary.file .. ".new") ~= binary.checksum then
      table.insert(toUpdate, { path = binary.file, checksum = binary.checksum, binary = true })
    end
  end

  if #toUpdate == 0 then
    g_logger.info("Lionfell client is up to date (" .. version .. ")")
    return finish()
  end

  g_logger.info(("Lionfell update %s: %d files"):format(version, #toUpdate))
  setStatus(tr("Downloading update (%d files)", #toUpdate))
  if updaterWindow then
    updaterWindow.downloadProgress:show()
    updaterWindow.downloadStatus:show()
  end
  downloadFiles(url, toUpdate, 1, 0, version)
end

-- public functions

-- Checks for a client update while the game is running (game_lionfell_restart: a server update is
-- under way and the player is disconnected). With an update it downloads it and restarts the client
-- as at startup; with none it calls onDone. Returns false when no check can run.
function Updater.checkDuringSession(onDone)
  if updaterWindow or not g_app.hasUpdater() then
    return false
  end
  finished = false
  loadModulesFunction = nil
  sessionCallback = onDone
  Updater.check()
  return true
end

function Updater.init(loadModulesFunc)
  loadModulesFunction = loadModulesFunc
  Updater.check()
end

function Updater.terminate()
  loadModulesFunction = nil
  sessionCallback = nil -- the client is closing (e.g. to install an update): nothing to report back
  finish()
end

-- skip the update and start with the files on disk
function Updater.abort()
  finish()
end

function Updater.fail(message)
  g_logger.warning("Lionfell update skipped: " .. tostring(message))
  if not updaterWindow then
    return finish()
  end
  if httpOperationId then
    HTTP.cancel(httpOperationId)
    httpOperationId = nil
  end
  removeEvent(scheduledEvent)
  setStatus(message .. "\n" .. tr("Starting without the update."))
  scheduledEvent = scheduleEvent(finish, 2000)
end

function Updater.check()
  if updaterWindow then return end
  updaterWindow = g_ui.displayUI('updater')
  updaterWindow:show()
  updaterWindow:raise()

  scheduledEvent = scheduleEvent(function()
    Updater.fail(tr("The update server did not answer."))
  end, Updater.checkTimeout)

  httpOperationId = HTTP.getJSON(baseUrl() .. "manifest.json", function(data, err)
    if finished then return end
    httpOperationId = nil -- answered: nothing left to cancel
    removeEvent(scheduledEvent)
    -- carry on in a frame of our own, not inside the HTTP answer: starting the game (every module
    -- loads) from within it crashed Windows clients with heap corruption when there was no update
    scheduleEvent(function()
      if finished then return end
      if err then
        -- no update server (offline, or none set up): start right away
        g_logger.warning("Lionfell update skipped, update server not reachable: " .. tostring(err))
        return finish()
      end
      onManifest(data)
    end, 10)
  end)
end
