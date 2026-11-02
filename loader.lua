-- Alan Hub loader
-- Downloads the newest alan_hub.lua and runs it:
--   * a random "no cache" tag on every download, so updates show up right away
--   * up to 3 rounds over two mirrors (GitHub raw, then jsDelivr)
--   * only runs the download if it really is Alan Hub (never an error page)

local URLS = {
    "https://raw.githubusercontent.com/ALANHUBROGUE/ALANHUB/main/alan_hub.lua",
    "https://cdn.jsdelivr.net/gh/ALANHUBROGUE/ALANHUB@main/alan_hub.lua",
}

local function fetch(url)
    local ok, body = pcall(httpget, url .. "?nocache=" .. tostring(math.random(1, 1000000000)))
    if ok and type(body) == "string" and body:sub(1, 11) == "-- Alan Hub" then
        return body
    end
    return nil
end

local source = nil
for attempt = 1, 3 do
    for _, url in ipairs(URLS) do
        source = fetch(url)
        if source then break end
    end
    if source then break end
    task.wait(1)
end

if source then
    loadstring(source)()
else
    warn("[Alan Hub] could not download the hub - check your internet connection and run it again")
end
