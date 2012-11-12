--[[



]]--

--- CONFINE jaon data io library.
module( "confine.data", package.seeall )



local nixio  = require "nixio"
local json   = require "luci.json"
local ltn12  = require "luci.ltn12"
local http   = require "luci.http.protocol"
local tools  = require "confine.tools"
local tree   = require "confine.tree"
local dbg    = tools.dbg

local wget               = "/usr/bin/wget %q -t3 -T2 --random-wait=1 -q -O- %q"
local wpost              = "/usr/bin/wget --no-check-certificate -q --post-data=%q -O- %q"

local json_pretty_print_tool   = "python -mjson.tool"




function file_put( data, file, dir )

	if dir then
		tools.mkdirr(dir)
	else
		dir = ""
	end


	dbg("updating RestApi at: "..dir..(file or ""))
	
	if file and data then
		local out = io.open(dir .. file, "w")
		assert(out, "Failed to open %s" %dir .. file)	
		ltn12.pump.all(json.Encoder(data):source(), ltn12.sink.file(out))
		
		if os.execute( 'echo "{}" | ' .. json_pretty_print_tool .. " > /dev/null" ) == 0 then
			local tmp = os.tmpname()
			local cmd = "cat "..dir..file.." | "..json_pretty_print_tool.." > "..tmp
--			dbg("json_pretty_print_tool=" .. json_pretty_print_tool .. " available! exec: "..cmd)
			
			os.execute( cmd )
			nixio.fs.move( tmp, dir..file)
		end
--		out:close()
	elseif data then
		local k,v
		for k,v in pairs(data) do
			file_put( v, k, dir )
		end
	end
end

function file_get( file )

	local fd = io.open(file, "r")
	if not fd then
		dbg("Failed to open %s" %file)
		return
	end
	
	local src = ltn12.source.file(fd)
	local jsd = json.Decoder()
	
	ltn12.pump.all(src, jsd:sink())

	return tree.copy_recursive_rebase_keys(jsd:get())

end




function http_get(url, base_uri, cert_file, cache)

	if not url then return nil end
	
	local base_key,index_key = tree.get_url_keys( url )
	local cached             = cache and cache[base_key] and cache[base_key][index_key] or false
	
	dbg("%6s url=%-60s base_key=%-13s index_key=%s",
	    cached and "cached" or "wget", base_uri..base_key..index_key, base_key, index_key)
	
	if cached then
		
		return cache[base_key][index_key], index_key
	
	else
		local cert_opt
		if cert_file then
			cert_opt = "--ca-certificate="..cert_file
		else
			cert_opt = "--no-check-certificate"
		end
		
		local cmd = wget %{ cert_opt, base_uri..base_key..index_key }	
		
		local fd = io.popen(cmd, "r")
		assert(fd, "Failed to execute %s" %{ cmd })
	
		local src = ltn12.source.file(fd)
		local jsd = json.Decoder()
	
		ltn12.pump.all(src, jsd:sink())
		local result = tree.copy_recursive_rebase_keys(jsd:get())
		
		--luci.util.dumptable(result)
			
	
		if cache then
			if not cache[base_key] then cache[base_key] = {} end
			cache[base_key][index_key] = result
		end
		
		return result, index_key
		
	end
end

function http_post(path, base_uri, data)

	dbg("post %s", path)

	local str = http.urlencode_params(data)
	local cmd = wpost %{ base_uri..path, str }

	local fd = io.popen(cmd, "r")
	assert(fd, "Failed to execute %s" %{ cmd })

	local src = ltn12.source.file(fd)
	local jsd = json.Decoder()

	ltn12.pump.all(src, jsd:sink())

	return jsd:get()
end

