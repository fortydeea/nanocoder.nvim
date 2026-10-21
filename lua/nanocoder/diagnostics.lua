-- Diagnostics sharing: the companion asks, we answer with vim.diagnostic data.
-- Direction: CLI -> Neovim (diagnostics_request), Neovim -> CLI
-- (diagnostics_response).
local client = require("nanocoder.client")
local log = require("nanocoder.log")
local protocol = require("nanocoder.protocol")

local M = {}

---Collect protocol-shaped diagnostics for one buffer or every listed buffer.
---@param file_path string|nil when nil, all buffers with diagnostics
---@return table[] diagnostics
function M.collect(file_path)
  local out = {}
  local bufnrs = {}

  if file_path and file_path ~= "" then
    local bufnr = vim.fn.bufnr(file_path)
    if bufnr ~= -1 then
      bufnrs = { bufnr }
    end
  else
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_get_name(bufnr) ~= "" then
        bufnrs[#bufnrs + 1] = bufnr
      end
    end
  end

  for _, bufnr in ipairs(bufnrs) do
    local diags = vim.diagnostic.get(bufnr)
    if #diags > 0 then
      for _, d in ipairs(protocol.diagnostics_from_vim(diags, bufnr)) do
        out[#out + 1] = d
      end
    end
  end

  return out
end

---Answer a diagnostics_request message.
---@param msg table { filePath? }
---@return boolean sent
function M.respond(msg)
  local diagnostics = M.collect(msg and msg.filePath or nil)
  local sent = client.send(protocol.diagnostics_response(diagnostics))
  log.debug(string.format("diagnostics_response -> %d entries", #diagnostics))
  return sent
end

function M.setup()
  local protocol_const = require("nanocoder.protocol")
  client.on(protocol_const.T_DIAGNOSTICS_REQUEST, function(msg)
    M.respond(msg)
  end)
  log.debug("diagnostics sharing enabled")
end

return M
