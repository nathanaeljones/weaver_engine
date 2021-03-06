require "pluto"

-- host object members
-- update_stat(k,v) set_stats(stats) 
-- newpage() print(tab, template) translate(str)
-- debuglog(str)
-- add_choice(id,label) set_choices(set)

-- get_mod_blob (id)
-- get_value_by(key, mod_id = nil, user_id = nil, partition = nil)
-- set_value_by(key, value, mod_id = nil, user_id = nil, partition = nil) 
-- flowstack_push(v) flowstack_pop() flowstack_peek()



-- function push(user_id, mod_id, method_name)
  --   Success {success=true}
  --   start_failed (goto or call failed (or module syntax error))



-- function resume(user_id, mod_id)

  -- Failure reasons {success=false, reason='reason', log=array_of_entries}

  -- empty_stack (new player, or secondary error went unhandled)
  -- dead_coroutine (abrupt_exit went unhandled)
  -- runtime_error (an error happened in the module)
  -- abrupt_exit (module stopped running without saying goodbye)
  -- infine_goto (infinite loop between modules)
  -- start_failed (goto or call failed (or module syntax error))

  -- Success {success=true, status="prompt"}


function resume(user_id, input)
  local loop_count = 0
  local engine_log = {}
  local err = function(msg)
    table.insert(engine_log,msg)
  end
  repeat
    -- Resume running the flow at the top of the stack
    local top_flow_wrapper = host.flowstack_peek()

    if top_flow_wrapper == nil then
      err("Stack is empty")
      return {success=false, reason="empty_stack", log=engine_log}
    end

    --host.stderr(table.show(top_flow_wrapper,"top_flow_wrapper"))

    local top_flow, persist_perms = sandbox.unpersist(top_flow_wrapper.binary, user_id, 
                                                              top_flow_wrapper.mod_id) 
    
    --host.stderr(top_flow)
    --host.stderr(table.show(persist_perms,"persist_perms"))

    if coroutine.status(top_flow.continuation) == 'dead' then
      err("Top of stack has dead coroutine: " ..top_flow.description)
      return {success=false, reason="dead_coroutine", log=engine_log}
    end

    err("Running flow "..top_flow.description.. " with ".. table.show(input, "input"))

    local was_started, result = coroutine.resume(top_flow.continuation, input)
    input = nil
    local is_dead = (coroutine.status(top_flow.continuation) == 'dead') -- Runtime errors or function ended
    local success = was_started and result and not is_dead

    err((success and "Successful" or "Failed").. " run: was_started=".. tostring(was_started)..
        ",  dead=" .. tostring(is_dead) .. ",  ".. table.show(result, "result"))

    if not was_started then
      err(result)
      return {success=false, reason="runtime_error", log=engine_log}
    end
    if was_started and is_dead then
      err("Module exited abruptly!")
      return {success=false, reason="abrupt_exit", log=engine_log}
    end
    -- Prevent endless loops
    if loop_count > 10 then
      err("Quitting (10 redirects without user input)")
      return {success=false, reason="infine_goto", log=engine_log}
    end
    loop_count = loop_count + 1
    
    -- Handle success
    if success then
      host.flowstack_pop()
      local key = result.status
      if key == 'prompt' then
        err("Success, saving updated flow...")
        local updated_flow = sandbox.persist(top_flow, persist_perms) 
        host.flowstack_pop()
        host.flowstack_push({binary=updated_flow, mod_id= top_flow.mod_id})
        return {success=true, status="prompt"}
      elseif key == 'donehere' then
        host.flowstack_pop()
        err("Module reports completion, popping flow from stack.")
      elseif key == 'call' or key == 'goto' then
        if key == 'goto' then
          err("Module requesting goto, popping flow from stack.")
          host.flowstack_pop()
        end

        local push_result = push(user_id,result.mod_id, result.method_name,err) 
        if not push_result.success then
          return push_result
        end

      end
    end
      
  until false
end

function push(user_id, mod_id, method_name, err)
  local log = {}
  if not err then
    err = function(msg)
      host.stderr(msg)
      table.insert(log,msg)
    end
  end
  local new_flow, persist_perms = build_coroutine(user_id, mod_id, method_name, err)
  if new_flow == nil then
    return {success=false, reason="start_failed", log=log}
  else
    
    local new_flow_binary = sandbox.persist(new_flow, persist_perms)
    local new_flow_wrapper = {binary=new_flow_binary, mod_id=mod_id}
    host.flowstack_push(new_flow_wrapper)
    --err("New flow pushed to stack: " .. table.show(new_flow_wrapper,"new_flow_wrapper"))
    return {success=true}
  end
end 

function build_coroutine(user_id, mod_id, method_name, err)
  -- Access the module source
  local mod_source = host.get_mod_blob(mod_id)
  if (mod_source == nil) then
    err ("Couldn't find module '" .. mod_id.."'")
    return nil
  end

  -- Create the sandboxed environment
  local env, persist_perms = sandbox.build_environment(user_id,mod_id)

  -- Load the module
  local mod = sandbox.load_with_env(mod_source,mod_id, env,err)
  if (mod == nil) then return nil end
  
  local err2 = function(e) return e.."\n"..debug.traceback() end
  -- Execute the module to populate the environment
  local status, result =  xpcall(mod,err2)
  if not status then
    err("Error evaluating module '" .. mod_id .. "'\n"..result)
    return nil
  end

  -- Look up the function from 'name'
  local initial_func = env[method_name]
  if (initial_func == nil) then
    err("Couldn't find function '" .. method_name .. "'' in module '" .. mod_id.."'")
    return nil
  end


  local code = coroutine.create(initial_func)
  -- Save the name so they can be recreated
  return {continuation=code, mod_id =mod_id, method_name=method_name, description=mod_id .."#"..method_name}, persist_perms
end


sandbox = {}
sandbox.env = {
  ipairs = ipairs,
  next = next,
  pairs = pairs,
  pcall = pcall,
  tonumber = tonumber,
  tostring = tostring,
  error = error,
  assert = assert,
  type = type,
  print = print,
  unpack = unpack,
  --sha2 = {sha256hex = sha2.sha256hex},
  coroutine = { create = coroutine.create, resume = coroutine.resume, 
      running = coroutine.running, status = coroutine.status, 
      wrap = coroutine.wrap, yield = coroutine.yield },
  string = { byte = string.byte, char = string.char, find = string.find, 
      format = string.format, gmatch = string.gmatch, gsub = string.gsub, 
      len = string.len, lower = string.lower, match = string.match, 
      rep = string.rep, reverse = string.reverse, sub = string.sub, 
      upper = string.upper },
  table = { insert = table.insert, maxn = table.maxn, remove = table.remove, 
      sort = table.sort, show = table.show, isempty = table.isempty},
  math = { abs = math.abs, acos = math.acos, asin = math.asin, 
      atan = math.atan, atan2 = math.atan2, ceil = math.ceil, cos = math.cos, 
      cosh = math.cosh, deg = math.deg, exp = math.exp, floor = math.floor, 
      fmod = math.fmod, frexp = math.frexp, huge = math.huge, 
      ldexp = math.ldexp, log = math.log, log10 = math.log10, max = math.max, 
      min = math.min, modf = math.modf, pi = math.pi, pow = math.pow, 
      rad = math.rad, random = math.random, sin = math.sin, sinh = math.sinh, 
      sqrt = math.sqrt, tan = math.tan, tanh = math.tanh },
  os = { clock = os.clock, difftime = os.difftime, time = os.time },
  debug = {getlocal = debug.getlocal}
  --debug = {getlocal = debug.getlocal} -- REMOVE THIS
}

sandbox.create_proxy_access = function(user_id, mod_id)
  local t = {}
  local metatable = {
    __index = function (t,k)
      return host.get_value_by(k,mod_id, user_id)
    end,
    __newindex = function (t,k,v)
      host.set_value_by(k,v,mod_id,user_id)
    end
  }
  setmetatable(t,metatable)
  return t
end

-- get_value_by(key, mod_id = nil, user_id = nil, partition = nil)
-- set_value_by(key, value, mod_id = nil, user_id = nil, partition = nil) 

sandbox.create_m = function(user_id, mod_id)
  local m = {}
  m.u = sandbox.create_proxy_access(user_id,mod_id)
  m.info = {}
  m.settings = sandbox.create_proxy_access(nil, mod_id)
  return m
end
sandbox.create_stats = function(user_id)
  -- TODO, replace raw access with validation and a table per value to offer helper methods
  return sandbox.create_proxy_access(user_id,nil)
end

sandbox.create_require = function(modulename, env)
  return function(modulename)
    local mod_source = host.get_mod_blob(modulename) -- TODO - make this return an array of module parts.
    if mod_source == nil then
      error("Failed to locate module '" .. modulename .."'")
    end
    local mod_loaded, message = loadstring(mod_source)
    if (mod_loaded == nil) then
      error("Failed to parse module " .. modulename .. ": ".. message)
    else
      setfenv(mod_loaded,env)
    end
    mod_loaded() -- Execute module without error handling (pcall)
  end
end

-- Loads and parses the specified file into a function, then sets its environment to 'env'. Errors go to the 'err' function.
sandbox.load_with_env = function(luacode, chunkname, env, error_callback)
  local func, message = loadstring(luacode, chunkname)
  if (func == nil) then
    error_callback(message)
  else
    setfenv(func,env)
  end
  return func
end


-- update_stat(k,v) set_stats(stats) 
-- newpage() print(tab, template) translate(str)
-- debuglog(str)
-- add_choice(id,label) set_choices(set)

-- get_mod_blob (id)
-- get_value_by(key, mod_id = nil, user_id = nil, partition = nil)
-- set_value_by(key, value, mod_id = nil, user_id = nil, partition = nil) 
-- flowstack_push(v) flowstack_pop() flowstack_peek()




sandbox.persistable = {[math.pi] = math.pi, [math.huge] = math.huge}
  
sandbox.non_env_persists = {
  host.get_value_by, 
  host.set_value_by,
  host.get_mod_blob,
  host.print,
  host.stderr,
  host,
  setmetatable,
  getmetatable,
  setfenv,
  loadstring, 
}

sandbox.build_persist_list = function(env, err)
  local list = table.flatten_to_functions_array(env,sandbox.persistable,err)
  for item,_ in pairs(sandbox.non_env_persists) do
    table.insert(list, item)
  end
  table.insert(list,env.stats) -- Because tables with metatables including C closures will fail
  table.insert(list,env.m)
  return table.invert(list)
end

-- Creates an environment by copying sandbox.env. Used for sandboxing.
sandbox.build_environment = function(user_id, mod_id)
  local env =  deepcopy(sandbox.env)
  env["_G"] = env  
  env.m = sandbox.create_m(user_id,mod_id)
  env.m.info.id = mod_id
  env.stats = sandbox.create_stats(user_id)

  env.require = sandbox.create_require(env)
  env.p = host.print
  env.newpage = host.newpage
  env.checkpoint = host.checkpoint

  env.m.exit_module = function()
    sandbox.env.coroutine.yield({status='donehere'})
  end

    env.add_choice = host.add_choice
  env.set_choices = host.set_choices
  env.get_choices = host.get_choices
  env.debuglog = host.stderr
  
  env.wait = function()
    --host.stderr(table.show(env.get_choices()))
    if table.isempty(env.get_choices()) then
      error("You must provide the user with one or more choices before waiting")
    end
    return sandbox.env.coroutine.yield({status='prompt'})
  end
  env.goto = function(moduleid, methodname)
    coroutine.yield({status="goto", mod_id = moduleid, method_name = methodname})
  end
  env.call = function(moduleid, methodname)
    coroutine.yield({status="call", mod_id = moduleid, method_name = methodname})
  end



  local err = function(msg)
    error(msg)
  end
  local persist_perms = sandbox.build_persist_list(env,err)
  return env, persist_perms
end

sandbox.unpersist = function(data, user_id,mod_id)
  local err = function(msg)
    error(msg)
  end
  local env, perms = sandbox.build_environment(user_id,mod_id)

  local result = pluto.unpersist(table.invert(perms),data)
  return result, perms
end

sandbox.persist = function(data, persist_perms)
  local persistit = function() return pluto.persist(persist_perms,data) end
  local status, err = pcall(persistit)
  if status then
    return(err) 
  else
    error(err.."\n\n"..table.show(data, "data") .."\n\n"..table.show(persist_perms, "persist_perms").."\n\n"..table.show(_G, "_G"))
  end 
end 
-- table.invert, table.flatten_to_functions_array
-- deepcopy(object)
