--[[



]]--


--- CONFINE system abstraction library.
module( "confine.system", package.seeall )

local nixio   = require "nixio"
local lsys    = require "luci.sys"
local uci     = require "confine.uci"
local tools   = require "confine.tools"
local data    = require "confine.data"
local null    = data.null



cache_file          = "/tmp/confine.cache"
	
www_dir             = "/www/confine"
rest_confine_dir    = "/tmp/confine"
rest_base_dir       = rest_confine_dir.."/api/"
rest_node_dir       = rest_confine_dir.."/api/node/"
rest_slivers_dir    = rest_confine_dir.."/api/slivers/"
rest_templates_dir  = rest_confine_dir.."/api/templates/"


function stop()
	pcall(nixio.fs.remover, rest_confine_dir)
	nixio.kill(nixio.getpid(),sig.SIGKILL)
end

function reboot()
	tools.dbg("rebooting...")
	tools.sleep(2)
	os.execute("reboot")
	stop()
end



function get_system_conf(sys_conf, arg)

	if uci.dirty( "confine" ) then return false end
	
	local conf = sys_conf or {}
	local flags = {}
	
	if arg then
		local trash
		flags,trash = tools.parse_flags(arg)
		assert( not trash, "Illegal flags: ".. tostring(trash) )
	end
	
		
	conf.debug          	   = conf.debug    or flags["debug"] or false
	conf.interval 		   = conf.interval or tonumber(flags["interval"] or 5)
	conf.count		   = conf.count    or tonumber(flags["count"] or 0)

	conf.id                    = tonumber((uci.getd("confine", "node", "id") or "x"), 16)
	conf.uuid                  = uci.getd("confine", "node", "uuid") or null
	conf.cert		   = null  -- http://wiki.openwrt.org/doc/howto/certificates.overview  http://man.cx/req
	conf.arch                  = tools.canon_arch(nixio.uname().machine)
	conf.soft_version          = (tools.subfindex( nixio.fs.readfile( "/etc/banner" ) or "???", "show%?branch=", "\n" ) or "???"):gsub("&rev=",".")

	conf.mgmt_ipv6_prefix48    = uci.getd("confine", "testbed", "mgmt_ipv6_prefix48")

	conf.node_base_uri         = "http://["..conf.mgmt_ipv6_prefix48..":".."%X"%conf.id.."::2]/confine/api"
--	conf.server_base_uri       = "https://controller.confine-project.eu/api"
	conf.server_base_uri       = lsys.getenv("SERVER_URI") or "http://["..conf.mgmt_ipv6_prefix48.."::2]/confine/api"
	
	conf.local_iface           = uci.getd("confine", "node", "local_ifname")
	
	conf.sys_state             = uci.getd("confine", "node", "state")
	conf.boot_sn               = tonumber(uci.getd("confine", "node", "boot_sn")) or 0

	conf.node_pubkey_file      = "/etc/dropbear/openssh_rsa_host_key.pub" --must match /etc/dropbear/dropbear_rsa_*
--	conf.server_cert_file      = "/etc/confine/keys/server.ca"
--	conf.node_cert_file        = "/etc/confine/keys/node.crt.pem" --must match /etc/uhttpd.crt and /etc/uhttpd.key

	conf.tinc_node_key_priv    = "/etc/tinc/confine/rsa_key.priv" -- required
	conf.tinc_node_key_pub     = "/etc/tinc/confine/rsa_key.pub"  -- created by confine_node_enable
	conf.tinc_hosts_dir        = "/etc/tinc/confine/hosts/"       -- required
	conf.tinc_conf_file        = "/etc/tinc/confine/tinc.conf"    -- created by confine_tinc_setup
	conf.tinc_pid_file         = "/var/run/tinc.confine.pid"
	
	conf.ssh_node_auth_file    = "/etc/dropbear/authorized_keys"


	
	conf.priv_ipv4_prefix      = uci.getd("confine", "node", "priv_ipv4_prefix24") .. ".0/24"
	conf.sliver_mac_prefix     = "0x" .. uci.getd("confine", "node", "mac_prefix16"):gsub(":", "")
	
	conf.sliver_pub_ipv4       = uci.getd("confine", "node", "sl_public_ipv4_proto")
	conf.sl_pub_ipv4_addrs     = uci.getd("confine", "node", "sl_public_ipv4_addrs")
	conf.sl_pub_ipv4_total     = tonumber(uci.getd("confine", "node", "public_ipv4_avail"))
	

	conf.direct_ifaces         = tools.str2table(uci.getd("confine", "node", "rd_if_iso_parents"),"[%a%d_]+")
	
	conf.lxc_if_keys           = uci.getd("lxc", "general", "lxc_if_keys" )

	conf.uci = {}
--	conf.uci.confine           = uci.get_all("confine")
	conf.uci.slivers           = uci.get_all("confine-slivers")

	return conf
end

function set_system_conf( sys_conf, opt, val)
	
	assert(opt and type(opt)=="string" and val, "set_system_conf()")
	
	if opt == "boot_sn" and
		type(val)=="number" and 		
		uci.set("confine", "node", opt, val) then
		
		return get_system_conf(sys_conf)
		
	elseif opt == "uuid" and
		type(val)=="string" and not uci.get("confine", "node", opt) and
		uci.set("confine", "node", opt, val) then
		
		return get_system_conf(sys_conf)
		
	elseif opt == "sys_state" and
		(val=="prepared" or val=="applied" or val=="failure") and
		uci.set("confine", "node", "state", val) then
		
		if val=="failure" then
			os.exec()
		end
		
		return get_system_conf(sys_conf)
		
	elseif opt == "priv_ipv4_prefix" and
		type(val)=="string" and val:gsub(".0/24",""):match("[0-255].[0-255].[0-255]") and
		uci.set("confine", "node", "priv_ipv4_prefix24", val:gsub(".0/24","") ) then
		
		return get_system_conf(sys_conf)
		
	elseif opt == "direct_ifaces" and
		type(val) == "table" then
		
		local devices = lsys.net.devices()
		
		local k,v
		for k,v in pairs(val) do
			if type(v)~="string" or not (v:match("^eth[%d]+$") or v:match("^wlan[%d]+$")) then
				dbg("set_system_conf() opt=%s val=%s Invalid interface prefix!", opt, tostring(v))
				devices = nil
				break
			end
			
			if not devices or not tools.get_table_by_key_val(devices,v) then
				dbg("set_system_conf() opt=%s val=%s Interface does NOT exist on system!",opt,tostring(v))
				devices = nil
				break
			end
		end
		
		if devices and uci.set("confine", "node", "rd_if_iso_parents", table.concat( val, " ") ) then
			return get_system_conf(sys_conf)
		end
		
	elseif opt == "sliver_mac_prefix" and
		type(val) == "string" then
		
		local dec = tonumber(val,16) or 0
		local msb = math.modf(dec / 256)
		local lsb = dec - (msb*256)
		
		if msb > 0 and msb <= 255 and lsb >= 0 and lsb <= 255 and
			uci.set("confine","node","mac_prefix16", "%.2x:%.2x"%{msb,lsb}) then
			
			return get_system_conf(sys_conf)
		end
	end
		
	assert(false, "set_system_conf(): Invalid opt=%s val=%s" %{opt, tostring(val)})
	
end

