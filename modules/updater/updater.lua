-- Lionfell client updater. On start, before the other modules load, the client fetches the
-- release manifest from the update server (Services.updater, set in init.lua) and downloads every
-- file whose checksum differs from the file on disk, then restarts into the new version.
--
-- Server side: tools/lionfell_release.py builds a release (manifest.json + files/) from the client
-- folder and tools/lionfell_update_server.py serves it. Manifest:
--   { version = "...", url = "files/", files = { ["modules/x/x.lua"] = "<crc32 hex>", ... },
--     binary = { file = "otclient", checksum = "<crc32 hex>" } }
-- Paths are real paths inside the client folder. A new binary is saved as otclient.new and
-- swapped in by the launcher (lionfell.sh) when the client restarts.
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

local function baseUrl()
  local url = Services.updater or ""
  if url:sub(-1) ~= "/" then
    url = url .. "/"
  end
  return url
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
  HTTP.cancel(httpOperationId)
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
  signalcall(g_app.onUpdateFinished, g_app)
end

-- start again through the launcher, which swaps in a downloaded binary
local function restart()
  local launcher = g_resources.getWorkDir() .. "lionfell.sh"
  if g_app.getOs() ~= "windows" and g_resources.fileExistsInWorkDir("lionfell.sh") and
      g_platform.spawnProcess("/bin/sh", { launcher, "--updated" }) then
    g_app.exit()
    return
  end
  g_app.restart()
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
    updaterWindow.downloadStatus:setText(entry.path)
    updaterWindow.downloadProgress:setPercent(0)
    updaterWindow.mainProgress:setPercent(math.floor(100 * (index - 1) / #toUpdate))
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
        updaterWindow.downloadProgress:setPercent(progress)
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

  local binary = data.binary
  if type(binary) == "table" and type(binary.file) == "string" and g_app.getOs() == "linux" then
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
function Updater.init(loadModulesFunc)
  loadModulesFunction = loadModulesFunc
  Updater.check()
end

function Updater.terminate()
  loadModulesFunction = nil
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
  HTTP.cancel(httpOperationId)
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
    removeEvent(scheduledEvent)
    if err then
      -- no update server (offline, or none set up): start right away
      g_logger.warning("Lionfell update skipped, update server not reachable: " .. tostring(err))
      return finish()
    end
    onManifest(data)
  end)
end
