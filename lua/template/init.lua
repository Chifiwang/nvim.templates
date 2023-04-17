local temp = {}
local uv, api, fn, fs = vim.loop, vim.api, vim.fn, vim.fs
local sep = uv.os_uname().sysname == 'Windows_NT' and '\\' or '/'

function temp.get_temp_list()
  temp.temp_dir = fs.normalize(temp.temp_dir)
  local res = {}

  local result = vim.fs.find(function(name)
    return name:match('.*')
  end, { type = 'file', path = temp.temp_dir, limit = math.huge })
  for _, name in ipairs(result) do
    local ft = vim.filetype.match({ filename = name })
    if ft then
      if not res[ft] then
        res[ft] = {}
      end
      res[ft][#res[ft] + 1] = name
    else
      vim.notify(
        '[Template.nvim] Could not find the filetype of template file ' .. name,
        vim.log.levels.INFO
      )
    end
  end

  return res
end

local expr = {
  '{{_date_}}',
  '{{_cursor_}}',
  '{{_file_name_}}',
  '{{_author_}}',
  '{{_email_}}',
  '{{_variable_}}',
  '{{_upper_file_}}',
  '{{_lua:(.*)_}}',
}

--@private
local expand_expr = {
  [expr[1]] = function(line)
    local date = os.date('%Y-%m-%d %H:%M:%S')
    return line:gsub(expr[1], date)
  end,
  [expr[2]] = function(line)
    return line:gsub(expr[2], '')
  end,
  [expr[3]] = function(line)
    local file_name = fn.expand('%:t:r')
    return line:gsub(expr[3], file_name)
  end,
  [expr[4]] = function(line)
    return line:gsub(expr[4], temp.author)
  end,
  [expr[5]] = function(line)
    return line:gsub(expr[5], temp.email)
  end,
  [expr[6]] = function(line)
    local var = vim.fn.input('Variable name: ', '')
    return line:gsub(expr[6], var)
  end,
  [expr[7]] = function(line)
    local file_name = string.upper(fn.expand('%:t:r'))
    return line:gsub(expr[7], file_name)
  end,
  [expr[8]] = function(line)
    return line:gsub(expr[8], load('return ' .. line:match(expr[8]))()) or line
  end,
}

--@private
local function create_and_load(file)
  local current_path = fn.getcwd()
  file = current_path .. sep .. file
  local ok, fd = pcall(uv.fs_open, file, 'w', 420)
  if not ok then
    vim.notify("Couldn't create file " .. file)
    return
  end
  uv.fs_close(fd)

  vim.cmd(':e ' .. file)
end

local function parse_args(args)
  local data = {}

  for _, v in pairs(args) do
    if v:find('%.%w+') then
      data.file = v
    end
    data.tp_name = v
  end

  return data
end

local function async_read(path, callback)
  uv.fs_open(path, 'r', 438, function(err, fd)
    assert(not err, err)
    ---@diagnostic disable-next-line: redefined-local
    uv.fs_fstat(fd, function(err, stat)
      assert(not err, err)
      ---@diagnostic disable-next-line: redefined-local
      uv.fs_read(fd, stat.size, 0, function(err, data)
        assert(not err, err)
        ---@diagnostic disable-next-line: redefined-local
        uv.fs_close(fd, function(err)
          assert(not err, err)
          return callback(data)
        end)
      end)
    end)
  end)
end

local function get_tpl(buf, name)
  local list = temp.get_temp_list()
  if not list[vim.bo[buf].filetype] then
    return
  end

  local ext = fn.expand('%:e')
  for _, v in ipairs(list[vim.bo[buf].filetype]) do
    if v:find(name) then
      return v
    end
  end
end

function temp:generate_template(args)
  local data = parse_args(args)

  if data.file then
    create_and_load(data.file)
  end

  local current_buf = api.nvim_get_current_buf()

  local tpl = get_tpl(current_buf, data.tp_name)
  if not tpl then
    return
  end

  local lines = {}

  async_read(
    tpl,
    ---@diagnostic disable-next-line: redefined-local
    vim.schedule_wrap(function(data)
      local cursor_pos = {}
      data = data:gsub('\r\n?', '\n')
      local tbl = vim.split(data, '\n')
      for i, line in pairs(tbl) do
        for idx, key in pairs(expr) do
          if line:find(key) then
            line = expand_expr[expr[idx]](line)

            if idx == 2 then
              cursor_pos = { i, 2 }
            end
          end
        end
        table.insert(lines, line)
      end

      local cur_line = api.nvim_win_get_cursor(0)[1]
      local start = cur_line
      if cur_line == 1 and #api.nvim_get_current_line() == 0 then
        start = cur_line - 1
      end
      api.nvim_buf_set_lines(current_buf, start, cur_line, false, lines)
      cursor_pos[1] = start ~= 0 and cur_line + cursor_pos[1] or cursor_pos[1]

      if next(cursor_pos) ~= nil then
        api.nvim_win_set_cursor(0, cursor_pos)
        vim.cmd('startinsert!')
      end
    end)
  )
end

function temp.in_template(buf)
  local list = temp.get_temp_list()
  if vim.tbl_isempty(list) or not list[vim.bo[buf].filetype] then
    return false
  end
  local bufname = api.nvim_buf_get_name(buf)

  if vim.tbl_contains(list[vim.bo[buf].filetype], bufname) then
    return true
  end

  return false
end

function temp.setup(config)
  vim.validate({
    config = { config, 't' },
  })

  if not config.temp_dir then
    vim.notify('[template.nvim] please config the temp_dir variable')
    return
  end

  temp.temp_dir = config.temp_dir

  temp.author = config.author and config.author or ''
  temp.email = config.email and config.email or ''

  local fts = vim.tbl_keys(temp.get_temp_list())

  if #fts == 0 then
    vim.notify('[template.nvim] does not get the filetype in template dir')
    return
  end

  api.nvim_create_autocmd('FileType', {
    pattern = fts,
    group = api.nvim_create_augroup('Template', { clear = false }),
    callback = function(opt)
      if temp.in_template(opt.buf) then
        vim.diagnostic.disable(opt.buf)
      end
    end,
  })
end

return temp
