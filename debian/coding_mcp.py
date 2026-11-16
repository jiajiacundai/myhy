#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
coding_mcp.py —— Coding Tools MCP 直连客户端（HTTP JSON-RPC，纯标准库，无需 SDK）
版本 2.0.0（2026-11-16 全面实测后修订）

用法一：当库用（推荐给 AI / 脚本）
    from coding_mcp import CodingMCP
    mcp = CodingMCP("https://host/mcp", "<access_token>")
    print(mcp.read_numbered("app.py"))          # 带行号读，便于定位
    r = mcp.edit("app.py", [{"op": "replace", "start_line": 10, "end_line": 12,
                             "content": "new line A\nnew line B"}])
    print(r["diff"])                            # 本地 unified diff，可直接贴进汇报
    r = mcp.run("python3 -m unittest -v")
    print(r["exit_code"], r["stdout"], r["stderr"])

用法二：当命令行用（url + token 传参或环境变量）
    export CODING_MCP_URL=https://host/mcp
    export CODING_MCP_TOKEN=<access_token>
    python3 coding_mcp.py selftest              # 一键端到端自检（写/改/补丁/执行/清理）
    python3 coding_mcp.py info
    python3 coding_mcp.py read app.py --numbered
    python3 coding_mcp.py edit app.py --start 10 --end 12 --from-file snippet.txt
    python3 coding_mcp.py replace-text app.py --old "foo" --new "bar"
    python3 coding_mcp.py run "pytest -q"
    python3 coding_mcp.py docs --out tools.md   # 生成全部工具的 AI 友好文档

设计要点（全部在本服务端实测验证过，封装里已处理）
  * 响应可能是 SSE：自动解析 data: 行；也兼容纯 JSON。
  * 服务端只接受相对路径：绝对路径会在本地被拦下并给出明确提示。
  * exec_command 的参数名是 cmd（不是 command）；workdir 也必须是相对路径。
  * 服务端 shell 是 dash（/bin/sh），不支持 set -o pipefail！
    run() 检测到管道时自动改用 `bash -o pipefail -c '<cmd>'` 包装（bash 已确认存在），
    既保留管道又保住 exit code；找不到 bash 时降级并给出 warning。
  * exec_command 超时未结束会转后台：run() 自动轮询到进程结束，
    write_stdin(chars="") 只返回“增量”输出，run() 会自己拼接完整 stdout/stderr。
    注意：stdin 只能在 spawn 时通过 exec_command(stdin=...) 传入；
    进程启动后 stdin 即关闭，write_stdin 只能用来轮询，不能交互输入。
  * exec 输出默认上限 65536 字节（verbosity=full 也不能突破该上限）：
    run() 默认 max_output_bytes=1MiB + verbosity=full；仍被截断时自动用
    read_output 按 output_ref 翻页重建完整输出（保留区 head+tail，中间被驱逐会如实报告）。
  * read_file 按字节截断（truncated=true）时，content 是 "\\n".join(行)，
    末尾不带换行符（哪怕最后一行是空行）；read_all() 翻页时会自动补回，
    保证拼出的内容与原文件逐字节一致（已实测）。
    另外 max_lines 会“静默截断”且不置 truncated 标志——翻页请用 max_bytes/next_start_line。
  * apply_changes 的 edits[].content 末尾带换行会“多插一个空行”：
    edit() 默认自动去掉尾部换行（可用 strip_trailing_newline=False 关闭）。
  * idempotency_key 与“完全相同的参数”绑定：同参重放返回 idempotent_replay=true，
    换任何参数（包括 dry_run）复用同一 key 会被 IDEMPOTENCY_KEY_REUSED 拒绝。
    edit()/write()/patch() 自动生成 `<key>:dryN` 与 `<key>:applyN` 两把不同的 key。
  * REVISION_MISMATCH：
    - edit() 自己读的 revision → 自动重读重试；但若“被改的行”内容也变了，
      拒绝盲重试并报错，要求重新规划行号。
    - 调用方显式钉住的 revision → 提交前先校验，过期立即抛 RevisionMismatch，
      绝不盲重试（防止覆盖别人刚改的内容）。
  * 工作区不是 git 仓库：git_diff 走服务端 fallback（新文件整体算 additions）。
    edit()/preview_diff() 额外提供本地 difflib unified diff，汇报不依赖 git。
  * 写入一律走 apply_changes / apply_patch，绝不用 exec_command 改文件。
  * 大文件/二进制：read_file 只支持 UTF-8 文本；图片用 view_image(save_to=...)。
"""

from __future__ import annotations

import argparse
import base64
import difflib
import json
import os
import re
import shlex
import sys
import time
import urllib.error
import urllib.request
import uuid
from typing import Any, Dict, Iterable, List, Optional, Sequence, Union

__all__ = ["CodingMCP", "MCPError", "RevisionMismatch", "TransportError", "DEFAULT_UA"]
__version__ = "2.0.0"

DEFAULT_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
              "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36")
PROTOCOL_VERSION = "2025-11-25"

# 会改变服务端状态的工具：重试必须带 idempotency_key
MUTATING_TOOLS = {"apply_changes", "apply_patch", "exec_command", "write_stdin", "kill_command"}

# 服务端 schema 硬上限
MAX_OUTPUT_BYTES = 1048576      # exec/write_stdin/read_output 单次上限
MAX_TIMEOUT_MS = 600000         # exec_command 进程寿命上限
MAX_YIELD_MS = 30000            # 单次调用等待上限


# --------------------------------------------------------------------------- #
# 异常
# --------------------------------------------------------------------------- #
class TransportError(Exception):
    """网络 / HTTP / 协议层失败。"""


class MCPError(Exception):
    """工具返回的业务错误（structuredContent.error 或 isError=true）。"""

    def __init__(self, code: str, message: str, *, category: str = "",
                 retryable: bool = False, details: Optional[dict] = None,
                 tool: str = "", text: str = ""):
        self.code = code
        self.message = message
        self.category = category
        self.retryable = retryable
        self.details = details or {}
        self.tool = tool
        self.text = text
        super().__init__(f"{code}: {message}" + (f" (category={category})" if category else ""))


class RevisionMismatch(MCPError):
    """文件自 read_file 之后被改动过。"""


def _clean(args: Dict[str, Any]) -> Dict[str, Any]:
    """丢掉 None，避免把 null 传给服务端触发 schema 校验失败。"""
    return {k: v for k, v in args.items() if v is not None}


def _rel(path: str) -> str:
    """服务端一律相对路径；这里提前拦截，省一次往返。"""
    if path is None:
        return "."
    p = str(path)
    if p in ("", "."):
        return "."
    if p.startswith("/") or p.startswith("\\") or p.startswith("~") or re.match(r"^[A-Za-z]:[\\/]", p):
        raise ValueError(
            f"路径必须是相对工作区的相对路径，收到 {path!r}。"
            "工作区根目录请写 '.'，子目录写 'doc'，不要写 /workspace/... 或 ~/..."
        )
    if p.startswith("./"):
        p = p[2:]
    return p


def _new_key(prefix: str = "cmcp") -> str:
    return f"{prefix}-{uuid.uuid4().hex[:16]}"


def _is_not_found(e: MCPError) -> bool:
    return e.code in ("NOT_FOUND", "FILE_NOT_FOUND", "PATH_NOT_FOUND", "ENOENT") \
        or e.category == "not_found"


# --------------------------------------------------------------------------- #
# 客户端
# --------------------------------------------------------------------------- #
class CodingMCP:
    """一个无状态 MCP 服务的薄封装：每次调用都是独立 POST，不需要 session。"""

    def __init__(self, url: Optional[str] = None, token: Optional[str] = None, *,
                 user_agent: str = DEFAULT_UA, timeout: float = 180.0,
                 max_retries: int = 3, verbose: bool = False,
                 auto_initialize: bool = True):
        self.url = url or os.getenv("CODING_MCP_URL") or os.getenv("MCP_URL") or ""
        self.token = token or os.getenv("CODING_MCP_TOKEN") or os.getenv("MCP_TOKEN") or ""
        if not self.url:
            raise ValueError("缺少 url：请传参或设置环境变量 CODING_MCP_URL")
        if not self.token:
            raise ValueError("缺少 token：请传参或设置环境变量 CODING_MCP_TOKEN")
        self.user_agent = user_agent
        self.timeout = timeout
        self.max_retries = max_retries
        self.verbose = verbose
        self.auto_initialize = auto_initialize
        self._id = 0
        self._initialized = False
        self.server_info_raw: Dict[str, Any] = {}
        self.protocol_version = PROTOCOL_VERSION
        self._tools_cache: Optional[List[dict]] = None
        self._bash_path: Optional[str] = None
        self._bash_checked = False

    # ---------------- 传输层 ---------------- #
    @property
    def headers(self) -> Dict[str, str]:
        # 四个头缺一不可，尤其 Accept 必须同时含 json 与 event-stream
        return {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": self.user_agent,
        }

    def _log(self, *a):
        if self.verbose:
            print("[coding_mcp]", *a, file=sys.stderr)

    @staticmethod
    def _parse_body(body: str) -> Optional[dict]:
        """兼容 application/json 与 text/event-stream(SSE)。"""
        body = (body or "").strip()
        if not body:
            return None
        if body.startswith("{") or body.startswith("["):
            try:
                obj = json.loads(body)
                if isinstance(obj, dict):
                    return obj
            except json.JSONDecodeError:
                pass
        result = None
        for line in body.splitlines():
            line = line.strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                obj = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict) and ("result" in obj or "error" in obj or "id" in obj):
                result = obj  # 取最后一条带结果的 data
        return result

    def _post(self, payload: dict, *, retry: bool = True) -> Optional[dict]:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        attempts = self.max_retries if retry else 1
        last = ""
        for i in range(attempts):
            req = urllib.request.Request(self.url, data=data, headers=self.headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    raw = resp.read().decode("utf-8", "replace")
                parsed = self._parse_body(raw)
                if parsed is None:
                    if payload.get("id") is None:      # 通知：空响应属正常
                        return None
                    raise TransportError(f"响应无法解析为 JSON-RPC：{raw[:400]!r}")
                return parsed
            except urllib.error.HTTPError as e:
                raw = e.read().decode("utf-8", "replace")
                parsed = self._parse_body(raw)
                if parsed is not None and "error" in parsed:
                    err = parsed["error"]
                    raise MCPError(str(err.get("code", "JSONRPC_ERROR")),
                                   str(err.get("message", "")), details=err.get("data") or {},
                                   text=raw)
                last = f"HTTP {e.code}: {raw[:400]}"
                if e.code not in (408, 425, 429, 500, 502, 503, 504):
                    raise TransportError(last)
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                last = f"{type(e).__name__}: {e}"
            if i < attempts - 1:
                delay = min(2 ** i, 8)
                self._log(f"retry {i + 1}/{attempts - 1} in {delay}s ({last})")
                time.sleep(delay)
        raise TransportError(f"请求失败（已重试 {attempts} 次）：{last}")

    def rpc(self, method: str, params: Optional[dict] = None, *,
            notify: bool = False, retry: bool = True) -> dict:
        msg: Dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            self._id += 1
            msg["id"] = self._id
        self._log("->", method, json.dumps(params, ensure_ascii=False)[:300] if params else "")
        out = self._post(msg, retry=retry)
        if notify:
            return {}
        if not isinstance(out, dict):
            raise TransportError(f"意外的 JSON-RPC 响应类型：{type(out).__name__}")
        if "error" in out:
            err = out["error"]
            raise MCPError(str(err.get("code", "JSONRPC_ERROR")), str(err.get("message", "")),
                           details=err.get("data") or {})
        return out.get("result", {})

    # ---------------- 握手 / 元信息 ---------------- #
    def initialize(self) -> dict:
        res = self.rpc("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "coding_mcp.py", "version": __version__},
        })
        self.server_info_raw = res
        self.protocol_version = res.get("protocolVersion", PROTOCOL_VERSION)
        self._initialized = True
        try:  # MCP 规范要求的初始化完成通知；无状态服务可能忽略，失败不影响使用
            self.rpc("notifications/initialized", {}, notify=True, retry=False)
        except Exception as e:
            self._log("notifications/ignored:", e)
        return res

    def ensure_ready(self):
        if self.auto_initialize and not self._initialized:
            self.initialize()

    def tools(self, refresh: bool = False) -> List[dict]:
        """tools/list 原始条目（含 inputSchema，便于自查参数名）。"""
        if self._tools_cache is None or refresh:
            self.ensure_ready()
            self._tools_cache = self.rpc("tools/list", {}).get("tools", [])
        return self._tools_cache

    def tool_names(self) -> List[str]:
        return [t["name"] for t in self.tools()]

    def tool_schema(self, name: str) -> dict:
        for t in self.tools():
            if t["name"] == name:
                return t
        raise MCPError("TOOL_NOT_FOUND", f"服务端没有工具 {name}", tool=name)

    def tools_doc(self) -> str:
        """把 tools/list 渲染成 Markdown 速查文档（给其他 AI 看最合适）。"""
        lines = ["# Coding Tools MCP 工具速查", "",
                 f"服务端：{self.server_info_raw.get('serverInfo', {}).get('name', '?')} "
                 f"v{self.server_info_raw.get('serverInfo', {}).get('version', '?')}，"
                 f"协议 {self.protocol_version}", ""]
        for t in self.tools():
            schema = t.get("inputSchema", {})
            props = schema.get("properties", {})
            req = set(schema.get("required", []))
            lines.append(f"## {t['name']}")
            lines.append("")
            lines.append(t.get("description", "").strip())
            lines.append("")
            if props:
                lines.append("| 参数 | 必填 | 类型 | 默认 | 说明 |")
                lines.append("|---|---|---|---|---|")
                for k, v in props.items():
                    desc = (v.get("description") or "").replace("\n", " ").replace("|", "\\|")
                    if len(desc) > 160:
                        desc = desc[:157] + "..."
                    typ = v.get("type", "?")
                    if "enum" in v:
                        typ += " " + "/".join(map(str, v["enum"]))
                    default = json.dumps(v["default"], ensure_ascii=False) if "default" in v else ""
                    lines.append(f"| {k} | {'是' if k in req else '否'} | {typ} | {default} | {desc} |")
                lines.append("")
        return "\n".join(lines)

    # ---------------- 通用调用 ---------------- #
    def call_raw(self, tool: str, arguments: Optional[dict] = None, *,
                 retry: Optional[bool] = None) -> dict:
        """返回完整 result（content / structuredContent / isError）。"""
        self.ensure_ready()
        args = arguments or {}
        if retry is None:
            retry = (tool not in MUTATING_TOOLS) or bool(args.get("idempotency_key"))
        return self.rpc("tools/call", {"name": tool, "arguments": args}, retry=retry)

    def call(self, tool: str, arguments: Optional[dict] = None, *,
             retry: Optional[bool] = None) -> Dict[str, Any]:
        """
        返回 structuredContent（服务端给了就用它，字段最齐全）；
        没有 structuredContent 时回退成 {"ok": True, "text": "..."}。
        业务错误统一抛 MCPError / RevisionMismatch。
        """
        res = self.call_raw(tool, arguments, retry=retry)
        text = "\n".join(c.get("text", "") for c in res.get("content", [])
                         if c.get("type") == "text")
        sc = res.get("structuredContent")
        is_err = bool(res.get("isError"))
        if isinstance(sc, dict):
            err = sc.get("error")
            if is_err or sc.get("ok") is False or isinstance(err, dict):
                err = err or {}
                code = str(err.get("code", "TOOL_ERROR"))
                cls = RevisionMismatch if code == "REVISION_MISMATCH" else MCPError
                raise cls(code, str(err.get("message", text)),
                          category=str(err.get("category", "")),
                          retryable=bool(err.get("retryable", False)),
                          details=err.get("details") or {}, tool=tool, text=text)
            out = dict(sc)
            out.setdefault("text", text)
            return out
        if is_err:
            m = re.match(r"^([A-Z0-9_]+):\s*(.*)", text, re.S)
            raise MCPError(m.group(1) if m else "TOOL_ERROR",
                           m.group(2) if m else text, tool=tool, text=text)
        return {"ok": True, "text": text}

    # ======================================================================= #
    # 一、只读工具（1:1 薄封装）
    # ======================================================================= #
    def server_info(self) -> dict:
        return self.call("server_info")

    def check_exec_environment(self) -> dict:
        return self.call("check_exec_environment")

    def read_file(self, path: str, start_line: Optional[int] = None,
                  end_line: Optional[int] = None, *, max_bytes: Optional[int] = None,
                  max_lines: Optional[int] = None, encoding: Optional[str] = None) -> dict:
        """
        读一个切片。返回字段重点：
          content / revision / total_lines / start_line / end_line
          truncated / truncated_by / next_start_line
        大文件要么给 start_line+end_line，要么用 read_all() 自动翻页。
        注意：max_lines 会静默截断（truncated 仍为 false），翻页别依赖它；
        按字节截断时 content 末尾不带换行符，read_all() 已处理该语义。
        """
        return self.call("read_file", _clean({
            "path": _rel(path), "start_line": start_line, "end_line": end_line,
            "max_bytes": max_bytes, "max_lines": max_lines, "encoding": encoding}))

    def list_dir(self, path: str = ".", *, recursive: bool = False,
                 max_depth: Optional[int] = None, max_entries: Optional[int] = None,
                 include_hidden: bool = False, include_ignored: bool = False,
                 sort: Optional[str] = None) -> dict:
        return self.call("list_dir", _clean({
            "path": _rel(path), "recursive": recursive, "max_depth": max_depth,
            "max_entries": max_entries, "include_hidden": include_hidden,
            "include_ignored": include_ignored, "sort": sort}))

    def list_files(self, glob: Optional[str] = None, *, patterns: Optional[Sequence[str]] = None,
                   path: Optional[str] = None, exclude_patterns: Optional[Sequence[str]] = None,
                   max_results: Optional[int] = None, include_hidden: bool = False,
                   include_ignored: bool = False, sort: Optional[str] = None) -> dict:
        return self.call("list_files", _clean({
            "glob": glob, "patterns": list(patterns) if patterns else None,
            "path": _rel(path) if path is not None else None,
            "exclude_patterns": list(exclude_patterns) if exclude_patterns else None,
            "max_results": max_results, "include_hidden": include_hidden,
            "include_ignored": include_ignored, "sort": sort}))

    def search_text(self, query: str, *, path: Optional[str] = None, regex: bool = False,
                    case_sensitive: bool = False, glob: Optional[str] = None,
                    include_globs: Optional[Sequence[str]] = None,
                    exclude_globs: Optional[Sequence[str]] = None,
                    context_lines: Optional[int] = None, max_results: Optional[int] = None,
                    max_preview_bytes: Optional[int] = None) -> dict:
        return self.call("search_text", _clean({
            "query": query, "path": _rel(path) if path is not None else None,
            "regex": regex, "case_sensitive": case_sensitive, "glob": glob,
            "include_globs": list(include_globs) if include_globs else None,
            "exclude_globs": list(exclude_globs) if exclude_globs else None,
            "context_lines": context_lines, "max_results": max_results,
            "max_preview_bytes": max_preview_bytes}))

    def view_image(self, path: str, *, auto_resize: bool = True,
                   max_bytes: Optional[int] = None, max_width: Optional[int] = None,
                   max_height: Optional[int] = None, save_to: Optional[str] = None) -> dict:
        """取工作区图片；save_to 给本地路径时把 base64 落盘成本地文件。"""
        self.ensure_ready()
        res = self.call_raw("view_image", _clean({
            "path": _rel(path), "auto_resize": auto_resize, "max_bytes": max_bytes,
            "max_width": max_width, "max_height": max_height}))
        out: Dict[str, Any] = dict(res.get("structuredContent") or {})
        for c in res.get("content", []):
            if c.get("type") == "image" and save_to:
                with open(save_to, "wb") as f:
                    f.write(base64.b64decode(c.get("data", "")))
                out["saved_to"] = save_to
        out.setdefault("text", "\n".join(c.get("text", "") for c in res.get("content", [])
                                         if c.get("type") == "text"))
        return out

    # ======================================================================= #
    # 二、执行工具
    # ======================================================================= #
    def exec_command(self, cmd: str, *, workdir: str = ".", env: Optional[dict] = None,
                     timeout_ms: Optional[int] = None, yield_time_ms: Optional[int] = None,
                     stdin: Optional[str] = None, tty: Optional[bool] = None,
                     max_output_bytes: Optional[int] = None,
                     preview_bytes: Optional[int] = None,
                     verbosity: Optional[str] = None) -> dict:
        """
        单次 exec_command（参数名是 cmd！）。不自动轮询；要等结束请用 run()。
        stdin 只能在这里传（进程启动后 stdin 即关闭，write_stdin 仅用于轮询）。
        输出上限由 max_output_bytes 决定（默认 65536，最大 1048576），
        verbosity=full 也不能突破该上限；要完整大输出请调大 max_output_bytes。
        """
        return self.call("exec_command", _clean({
            "cmd": cmd, "workdir": _rel(workdir), "env": env,
            "timeout_ms": timeout_ms, "yield_time_ms": yield_time_ms, "stdin": stdin,
            "tty": tty, "max_output_bytes": max_output_bytes,
            "preview_bytes": preview_bytes, "verbosity": verbosity}))

    def write_stdin(self, command_id: str, chars: str = "", *,
                    yield_time_ms: Optional[int] = None,
                    max_output_bytes: Optional[int] = None,
                    preview_bytes: Optional[int] = None,
                    verbosity: Optional[str] = None) -> dict:
        """chars="" 是轮询等输出（返回增量）。非空 chars 仅极少数场景可用：
        本服务端进程启动后 stdin 即关闭，交互输入请在 exec_command(stdin=...) 传。"""
        return self.call("write_stdin", _clean({
            "command_id": command_id, "chars": chars, "yield_time_ms": yield_time_ms,
            "max_output_bytes": max_output_bytes, "preview_bytes": preview_bytes,
            "verbosity": verbosity}))

    def kill_command(self, command_id: str, *, signal: Optional[str] = None,
                     kill_wait_ms: Optional[int] = None, wait_ms: Optional[int] = None,
                     max_output_bytes: Optional[int] = None,
                     preview_bytes: Optional[int] = None,
                     verbosity: Optional[str] = None) -> dict:
        return self.call("kill_command", _clean({
            "command_id": command_id, "signal": signal, "kill_wait_ms": kill_wait_ms,
            "wait_ms": wait_ms, "max_output_bytes": max_output_bytes,
            "preview_bytes": preview_bytes, "verbosity": verbosity}))

    def read_output(self, output_ref: str, *, offset: Optional[int] = None,
                    limit: Optional[int] = None, stream: Optional[str] = None) -> dict:
        """output_ref 形如 command:<command_id>:stdout。保留区为 head+滚动 tail。"""
        return self.call("read_output", _clean({
            "output_ref": output_ref, "offset": offset, "limit": limit, "stream": stream}))

    def read_output_all(self, output_ref: str, *, max_total: int = 8 * 1048576) -> dict:
        """按 next_offset 翻页取回某条流的全部保留输出；返回 content/evicted_gap_bytes。"""
        parts: List[str] = []
        offset = 0
        gap = 0
        total = 0
        while total < max_total:
            d = self.read_output(output_ref, offset=offset, limit=MAX_OUTPUT_BYTES)
            chunk = d.get("content", "") or ""
            parts.append(chunk)
            total += len(chunk.encode("utf-8", "replace"))
            gap = max(gap, int(d.get("evicted_gap_bytes") or 0))
            nxt = d.get("next_offset")
            if nxt is None or nxt <= offset or not chunk:
                break
            offset = nxt
        return {"ok": True, "content": "".join(parts), "evicted_gap_bytes": gap,
                "bytes": total}

    def _find_bash(self) -> Optional[str]:
        """探测服务端 bash（dash 不支持 pipefail，需要 bash 包装）。结果缓存。"""
        if not self._bash_checked:
            self._bash_checked = True
            try:
                r = self.exec_command("command -v bash", yield_time_ms=8000,
                                      verbosity="full")  # summary 模式不返回 stdout 字段
                path = (r.get("stdout") or "").strip().splitlines()
                self._bash_path = path[0].strip() if path and path[0].strip() else None
            except MCPError:
                self._bash_path = None
            self._log("bash path:", self._bash_path)
        return self._bash_path

    def run(self, cmd: str, *, workdir: str = ".", env: Optional[dict] = None,
            timeout: float = 300.0, pipefail: bool = True, check: bool = False,
            poll_ms: int = 15000, max_polls: int = 400,
            max_output_bytes: int = MAX_OUTPUT_BYTES,
            verbosity: str = "full") -> dict:
        """
        跑一条命令并等它结束，返回完整结果：
          {ok, status, exit_code, stdout, stderr, timed_out, signal, command_id,
           elapsed_ms, cmd, polls, truncated, warnings}
        - 服务端 shell 是 dash：检测到管道且 pipefail=True 时自动用
          `bash -o pipefail -c '<cmd>'` 包装，保住 exit code（实测有效）。
        - 默认 max_output_bytes=1MiB + verbosity=full；仍截断时用 read_output
          翻页重建完整输出；保留区之外的中段被驱逐会写进 warnings。
        - 自动轮询后台进程；write_stdin 的增量输出会被拼成完整 stdout/stderr。
        - timeout 超过服务端上限 600s 时自动截断并警告。
        - check=True 时非 0 退出码抛 MCPError。
        注意：本函数只用来跑验证/测试，禁止用它改文件（服务端明确禁止）。
        """
        warnings: List[str] = []
        real_cmd = cmd
        if pipefail and "|" in cmd and "pipefail" not in cmd:
            bash = self._find_bash()
            if bash:
                real_cmd = f"{bash} -o pipefail -c {shlex.quote(cmd)}"
            else:
                warnings.append("服务端找不到 bash，无法注入 pipefail；"
                                "管道命令的 exit code 可能失真，建议避免管道")
        want_ms = int(timeout * 1000)
        timeout_ms = min(want_ms, MAX_TIMEOUT_MS)
        if want_ms > MAX_TIMEOUT_MS:
            warnings.append(f"timeout={timeout}s 超过服务端上限，已按 600s 执行")
        first = self.exec_command(real_cmd, workdir=workdir, env=env,
                                  timeout_ms=timeout_ms,
                                  yield_time_ms=min(poll_ms, MAX_YIELD_MS),
                                  max_output_bytes=max_output_bytes, verbosity=verbosity)
        out_chunks = [first.get("stdout", "") or ""]
        err_chunks = [first.get("stderr", "") or ""]
        cur = first
        polls = 0
        saw_trunc = bool(first.get("stdout_truncated") or first.get("stderr_truncated")
                         or first.get("truncated"))
        while cur.get("status") == "running" and polls < max_polls:
            cid = cur.get("command_id")
            if not cid:
                break
            cur = self.write_stdin(cid, "", yield_time_ms=min(poll_ms, MAX_YIELD_MS),
                                   max_output_bytes=max_output_bytes, verbosity=verbosity)
            out_chunks.append(cur.get("stdout", "") or "")
            err_chunks.append(cur.get("stderr", "") or "")
            saw_trunc = saw_trunc or bool(cur.get("stdout_truncated")
                                          or cur.get("stderr_truncated") or cur.get("truncated"))
            polls += 1
        stdout = "".join(out_chunks)
        stderr = "".join(err_chunks)
        # 截断过 → 用保留输出重建（head+tail 全量翻页），比增量拼接更可靠
        refs = cur.get("output_refs") or first.get("output_refs") or {}
        if saw_trunc and refs:
            for stream, joined in (("stdout", stdout), ("stderr", stderr)):
                ref = refs.get(stream)
                if not ref:
                    continue
                try:
                    full = self.read_output_all(ref)
                    if len(full["content"]) >= len(joined):
                        if stream == "stdout":
                            stdout = full["content"]
                        else:
                            stderr = full["content"]
                    if full["evicted_gap_bytes"] > 0:
                        warnings.append(f"{stream} 中段有 {full['evicted_gap_bytes']} 字节"
                                        "超出服务端保留区被驱逐，无法恢复；"
                                        "超大输出请重定向到文件再用 read_file 分页读")
                except MCPError as e:
                    warnings.append(f"read_output 重建 {stream} 失败：{e}")
        elif saw_trunc:
            warnings.append("输出被截断且无 output_ref 可重建；"
                            "请重定向到文件再用 read_file 分页读")
        result = {
            "ok": cur.get("status") == "exited" and cur.get("exit_code") == 0,
            "status": cur.get("status"),
            "exit_code": cur.get("exit_code"),
            "stdout": stdout,
            "stderr": stderr,
            "timed_out": bool(cur.get("timed_out")),
            "signal": cur.get("signal"),
            "command_id": first.get("command_id"),
            "elapsed_ms": cur.get("elapsed_ms"),
            "cmd": real_cmd,
            "polls": polls,
            "truncated": saw_trunc,
            "warnings": warnings,
        }
        if result["status"] == "running":
            result["note"] = ("命令仍在运行，可用 write_stdin(command_id, '') 继续等，"
                              "或 kill_command(command_id) 终止")
        if check and not result["ok"]:
            raise MCPError("COMMAND_FAILED",
                           f"exit_code={result['exit_code']} status={result['status']}\n"
                           f"stdout:\n{result['stdout']}\nstderr:\n{result['stderr']}",
                           tool="exec_command", details=result)
        return result

    # ======================================================================= #
    # 三、Git 只读（工作区非 git 仓库时服务端走 fallback，可能只有整体 additions）
    # ======================================================================= #
    def git_status(self, *, path: Optional[str] = None, include_untracked: bool = True,
                   max_entries: Optional[int] = None) -> dict:
        return self.call("git_status", _clean({
            "path": _rel(path) if path is not None else None,
            "include_untracked": include_untracked, "max_entries": max_entries}))

    def git_diff(self, *, paths: Optional[Sequence[str]] = None, path: Optional[str] = None,
                 staged: bool = False, unstaged: bool = True, include_untracked: bool = True,
                 context_lines: Optional[int] = None, max_bytes: Optional[int] = None) -> dict:
        return self.call("git_diff", _clean({
            "paths": [_rel(p) for p in paths] if paths else None,
            "path": _rel(path) if path is not None else None,
            "staged": staged, "unstaged": unstaged, "include_untracked": include_untracked,
            "context_lines": context_lines, "max_bytes": max_bytes}))

    def git_log(self, *, max_count: Optional[int] = None, path: Optional[str] = None,
                ref: Optional[str] = None, skip: Optional[int] = None) -> dict:
        return self.call("git_log", _clean({
            "max_count": max_count, "path": _rel(path) if path is not None else None,
            "ref": ref, "skip": skip}))

    def git_show(self, *, rev: Optional[str] = None, paths: Optional[Sequence[str]] = None,
                 path: Optional[str] = None, include_diff: bool = True,
                 context_lines: Optional[int] = None, max_bytes: Optional[int] = None) -> dict:
        return self.call("git_show", _clean({
            "rev": rev, "paths": [_rel(p) for p in paths] if paths else None,
            "path": _rel(path) if path is not None else None, "include_diff": include_diff,
            "context_lines": context_lines, "max_bytes": max_bytes}))

    def git_blame(self, path: str, *, start_line: Optional[int] = None,
                  end_line: Optional[int] = None, max_lines: Optional[int] = None,
                  rev: Optional[str] = None) -> dict:
        return self.call("git_blame", _clean({
            "path": _rel(path), "start_line": start_line, "end_line": end_line,
            "max_lines": max_lines, "rev": rev}))

    def request_permissions(self, tool_name: str, permission: str, reason: str,
                            arguments: dict, *, scope: Optional[str] = None,
                            ttl_seconds: Optional[int] = None) -> dict:
        return self.call("request_permissions", _clean({
            "tool_name": tool_name, "permission": permission, "reason": reason,
            "arguments": arguments, "scope": scope, "ttl_seconds": ttl_seconds}))

    # ======================================================================= #
    # 四、写入：底层两个工具
    # ======================================================================= #
    def apply_changes(self, changes: Sequence[dict], *, dry_run: bool = False,
                      idempotency_key: Optional[str] = None) -> dict:
        """
        行号寻址的原子改动。changes 每项：
          {"action": "create|write|edit|delete|move|copy", "path": ...,
           "revision": <edit/delete/move/copy 必填；write 且文件已存在时必填>,
           "content": <create/write 用整份文本>,
           "edits": [{"op":"replace|delete|insert_after|insert_before",
                      "start_line":N,"end_line":M,"line":N,"content":"..."}],
           "destination": <move/copy 目标，必须不存在>}
        注意：同一个 path 一次调用只能出现一次；行号全部相对“改动前”的原文件；
        create 拒绝带 revision；write 新建时可省略 revision。
        """
        return self.call("apply_changes", _clean({
            "changes": list(changes), "dry_run": dry_run,
            "idempotency_key": idempotency_key}))

    def apply_patch(self, patch: str, *, dry_run: bool = False,
                    idempotency_key: Optional[str] = None) -> dict:
        """
        V4A 上下文锚点补丁。信封格式：
          *** Begin Patch
          *** Update File: app.py
          @@ optional context anchor
          -old line
          +new line
           unchanged context line
          *** End Patch
        也支持 *** Add File: / *** Delete File: / *** Move to:。
        锚点只能向前搜索，找不到就失败（不会回退到前面去匹配）。
        返回 affected_files[].match_quality（exact / 忽略尾空白 / 忽略缩进）。
        """
        return self.call("apply_patch", _clean({
            "patch": patch, "dry_run": dry_run, "idempotency_key": idempotency_key}))

    # ======================================================================= #
    # 五、高层便捷函数（AI 日常主要用这些）
    # ======================================================================= #
    def read(self, path: str, *, start_line: Optional[int] = None,
             end_line: Optional[int] = None) -> dict:
        """read_file 的别名，语义更短。"""
        return self.read_file(path, start_line, end_line)

    def read_all(self, path: str, *, chunk_bytes: int = 120000) -> dict:
        """
        自动按 next_start_line 翻页读完整文件；返回 content/revision/total_lines。
        已处理服务端“截断块末尾不带换行”的语义：非末块统一补一个 \\n，
        拼接结果与原文件逐字节一致（实测验证）。
        """
        parts: List[str] = []
        start: Optional[int] = 1
        revision = None
        total_lines = None
        chunks = 0
        while True:
            d = self.read_file(path, start_line=start, max_bytes=chunk_bytes)
            if d.get("first_line_exceeds_limit"):
                raise MCPError("LINE_TOO_LONG",
                               f"{path} 第 {start} 行超过 chunk_bytes={chunk_bytes}，"
                               "请调大 chunk_bytes（最大 1048576）", tool="read_file")
            if revision is None:
                revision = d["revision"]
                total_lines = d.get("total_lines")
            elif d["revision"] != revision:
                raise RevisionMismatch("REVISION_MISMATCH",
                                       f"{path} 在分段读取过程中被改动，请重新读取",
                                       tool="read_file")
            part = d.get("content", "")
            nxt = d.get("next_start_line")
            more = bool(d.get("truncated")) and bool(nxt) and nxt > (start or 1)
            if more:
                # 截断块 content="\n".join(行)，末尾换行被服务端统一去掉；
                # 即使末行是空行（join 结果以 \n 结尾）也仍缺一个换行，统一补回。
                part += "\n"
            parts.append(part)
            chunks += 1
            if not more:
                break
            start = nxt
        return {"ok": True, "path": _rel(path), "content": "".join(parts),
                "revision": revision, "total_lines": total_lines, "chunks": chunks}

    def read_numbered(self, path: str, *, start_line: Optional[int] = None,
                      end_line: Optional[int] = None, width: Optional[int] = None) -> str:
        """带行号返回，方便挑 apply_changes 的行号。首行是 revision/截断提示。"""
        d = self.read_file(path, start_line, end_line)
        first = d.get("start_line", 1)
        total = d.get("total_lines")
        if width is None:
            width = max(4, len(str(total or 0)))
        body = d.get("content", "")
        lines = body.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        head = (f"[{path} lines {first}-{d.get('end_line')} of {total} "
                f"revision={d.get('revision')}]")
        if d.get("truncated"):
            head += (f" [TRUNCATED by {d.get('truncated_by')}; "
                     f"next_start_line={d.get('next_start_line')}，"
                     "继续读请带 start_line，或用 read --all]")
        return head + "\n" + "\n".join(f"{first + i:{width}d}|{ln}" for i, ln in enumerate(lines))

    def revision(self, path: str) -> str:
        """只读一行，拿当前 revision（最便宜的版本探测）。"""
        return self.read_file(path, 1, 1)["revision"]

    def exists(self, path: str) -> bool:
        try:
            self.read_file(path, 1, 1)
            return True
        except MCPError as e:
            if _is_not_found(e):
                return False
            raise

    def ls(self, path: str = ".", **kw) -> dict:
        return self.list_dir(path, **kw)

    def grep(self, query: str, **kw) -> dict:
        return self.search_text(query, **kw)

    def diff(self, paths: Optional[Sequence[str]] = None, **kw) -> str:
        """服务端 git diff 文本；非 git 仓库时是 fallback（新文件整体算 additions）。
        想要“本次改动”的精确 diff，请用 edit() 返回的 diff 或 preview_diff()。"""
        d = self.git_diff(paths=paths, **kw)
        return d.get("diff") or d.get("text") or ""

    # ---------------- 本地 diff 模拟（不依赖 git） ---------------- #
    @staticmethod
    def _split_lines(content: str) -> List[str]:
        lines = content.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        return lines

    @staticmethod
    def _simulate_edits(content: str, edits: Sequence[dict]) -> str:
        """在本地按服务端语义模拟行编辑，仅用于生成 diff 预览（服务端结果才是权威）。
        所有行号都相对原文件；content 为整行文本，"" 表示零行。"""
        lines = CodingMCP._split_lines(content)
        trailing_nl = content.endswith("\n")
        ops = []
        for e in edits:
            op = e.get("op")
            raw = e.get("content", "") or ""
            new = raw.split("\n") if raw else []
            if op in ("replace", "delete"):
                a = int(e.get("start_line", 1))
                b = int(e.get("end_line", a))
                ops.append((a - 1, b, [] if op == "delete" else new))
            elif op == "insert_after":
                n = int(e.get("line", 0))
                ops.append((n, n, new))
            elif op == "insert_before":
                n = int(e.get("line", 1))
                ops.append((n - 1, n - 1, new))
            else:
                raise ValueError(f"未知 edit op: {op!r}")
        for a, b, new in sorted(ops, key=lambda t: (t[0], t[1]), reverse=True):
            lines[a:b] = new
        out = "\n".join(lines)
        if trailing_nl and out:
            out += "\n"
        return out

    @staticmethod
    def _unified_diff(old: str, new: str, path: str) -> str:
        return "".join(difflib.unified_diff(
            old.splitlines(keepends=True), new.splitlines(keepends=True),
            fromfile=f"a/{path}", tofile=f"b/{path}", n=3))

    def preview_diff(self, path: str, edits: Sequence[dict], *,
                     strip_trailing_newline: bool = True) -> str:
        """不改文件，只返回“这些行编辑将会产生的” unified diff（本地模拟）。"""
        d = self.read_all(path)
        norm = self._normalize_edits(edits, strip_trailing_newline)
        return self._unified_diff(d["content"], self._simulate_edits(d["content"], norm), _rel(path))

    # ---------------- 写入封装 ---------------- #
    @staticmethod
    def _normalize_edits(edits: Iterable[dict], strip_trailing_newline: bool) -> List[dict]:
        out = []
        for e in edits:
            e = dict(e)
            if strip_trailing_newline and isinstance(e.get("content"), str):
                # 服务端语义：content 末尾的换行会额外插入一个空行
                e["content"] = e["content"].rstrip("\n")
            out.append(e)
        return out

    def _addressed_snapshot(self, path: str, edits: Sequence[dict]) -> Dict[str, Any]:
        d = self.read_all(path)
        lines = self._split_lines(d["content"])
        touched = {}
        for e in edits:
            if e.get("op") in ("replace", "delete"):
                a = e.get("start_line", 1)
                b = e.get("end_line", a)
                touched[f"{a}-{b}"] = lines[a - 1:b]
            else:
                a = e.get("line", 0)
                touched[f"anchor{a}"] = lines[max(0, a - 1):a + 1]
        return {"revision": d["revision"], "total_lines": d["total_lines"],
                "touched": touched, "content": d["content"]}

    def edit(self, path: str, edits: Sequence[dict], *, dry_run: bool = False,
             preview: bool = True, revision: Optional[str] = None,
             idempotency_key: Optional[str] = None, strip_trailing_newline: bool = True,
             retries: int = 2) -> dict:
        """
        改一个文件（行号寻址），自动做完这套流程：
          读 revision → dry_run 预览 → 同一 revision 正式提交（各用独立 idempotency_key）
          → REVISION_MISMATCH 时重读重试（被改的行内容变了则拒绝盲重试）
        返回 {"preview", "result", "revision", "diff", "ok"}；
        diff 是本地模拟的 unified diff，可直接用于汇报。
        dry_run=True 时只预览不提交，result 为 None。
        显式传 revision 时：提交前先校验它是否仍是最新，过期立即抛 RevisionMismatch，
        绝不盲重试（防止覆盖他人改动）；不传则自动读取并允许安全重试。
        """
        path = _rel(path)
        edits = self._normalize_edits(edits, strip_trailing_newline)
        base_key = idempotency_key or _new_key("edit")
        if revision is not None:
            current = self.revision(path)
            if current != revision:
                raise RevisionMismatch(
                    "REVISION_MISMATCH",
                    f"{path} 你钉住的 revision 已过期（文件已被改动）。"
                    "请重新 read_numbered 规划行号后再提交；不会盲目重试。",
                    category="conflict", tool="apply_changes",
                    details={"pinned": revision, "current": current})
        snap = self._addressed_snapshot(path, edits) if retries > 0 else None
        rev = revision or (snap["revision"] if snap else self.revision(path))
        local_diff = self._unified_diff(snap["content"],
                                        self._simulate_edits(snap["content"], edits), path) \
            if snap else None
        last_err: Optional[Exception] = None
        for attempt in range(retries + 1):
            change = {"action": "edit", "path": path, "revision": rev, "edits": edits}
            try:
                pre = None
                if preview and not dry_run:
                    pre = self.apply_changes([change], dry_run=True,
                                             idempotency_key=f"{base_key}:dry{attempt}")
                if dry_run:
                    return {"preview": self.apply_changes([change], dry_run=True,
                                                          idempotency_key=f"{base_key}:dry{attempt}"),
                            "result": None, "revision": rev, "diff": local_diff, "ok": True}
                res = self.apply_changes([change], dry_run=False,
                                         idempotency_key=f"{base_key}:apply{attempt}")
                files = res.get("affected_files") or []
                new_rev = files[0].get("revision") if files else None
                return {"preview": pre, "result": res, "revision": new_rev,
                        "diff": local_diff, "ok": True}
            except RevisionMismatch as e:
                last_err = e
                if attempt >= retries:
                    break
                new_snap = self._addressed_snapshot(path, edits)
                if snap and new_snap["touched"] != snap["touched"]:
                    raise MCPError(
                        "REVISION_MISMATCH_UNSAFE_RETRY",
                        f"{path} 已被他人改动，且你要改的那些行内容也变了；"
                        "请重新 read_numbered 后重新规划行号，不要盲目重试。",
                        category="conflict", tool="apply_changes",
                        details={"old": snap["touched"], "new": new_snap["touched"]})
                snap, rev = new_snap, new_snap["revision"]
                local_diff = self._unified_diff(snap["content"],
                                                self._simulate_edits(snap["content"], edits), path)
                self._log(f"REVISION_MISMATCH -> 重读重试 attempt={attempt + 1} rev={rev}")
        raise last_err if last_err else MCPError("EDIT_FAILED", "未知失败", tool="apply_changes")

    # 单操作快捷方式
    def replace_lines(self, path: str, start_line: int, end_line: int, content: str, **kw) -> dict:
        return self.edit(path, [{"op": "replace", "start_line": start_line,
                                 "end_line": end_line, "content": content}], **kw)

    def insert_after(self, path: str, line: int, content: str, **kw) -> dict:
        """line=0 表示插到文件最前面。"""
        return self.edit(path, [{"op": "insert_after", "line": line, "content": content}], **kw)

    def insert_before(self, path: str, line: int, content: str, **kw) -> dict:
        return self.edit(path, [{"op": "insert_before", "line": line, "content": content}], **kw)

    def delete_lines(self, path: str, start_line: int, end_line: Optional[int] = None, **kw) -> dict:
        return self.edit(path, [{"op": "delete", "start_line": start_line,
                                 "end_line": end_line or start_line}], **kw)

    def append(self, path: str, content: str, **kw) -> dict:
        """追加到文件末尾（自动取 total_lines 作为锚点）。"""
        total = self.read_file(path, 1, 1).get("total_lines") or 0
        return self.insert_after(path, total, content, **kw)

    def prepend(self, path: str, content: str, **kw) -> dict:
        """插到文件最前面。"""
        return self.insert_after(path, 0, content, **kw)

    def replace_text(self, path: str, old: str, new: str, *, count: int = -1,
                     expected_occurrences: Optional[int] = None,
                     dry_run: bool = False, preview: bool = True,
                     idempotency_key: Optional[str] = None) -> dict:
        """
        文本替换（读全文 → 本地 replace → 带 revision 整份写回，走 dry_run 预览）。
        count=-1 替换全部；expected_occurrences 给定时数量不符立即报错（防改错）。
        返回 {"occurrences", "preview", "result", "revision", "diff", "ok"}。
        适合“按内容锚点”的小改动；大文件(>1MiB)请改用行号 edit 或 apply_patch。
        """
        path = _rel(path)
        d = self.read_all(path)
        content = d["content"]
        found = content.count(old)
        if found == 0:
            raise MCPError("TEXT_NOT_FOUND", f"{path} 中找不到要替换的文本（{len(old)} 字符）",
                           tool="replace_text", details={"old_preview": old[:200]})
        if expected_occurrences is not None and found != expected_occurrences:
            raise MCPError("OCCURRENCE_COUNT_MISMATCH",
                           f"{path} 期望 {expected_occurrences} 处匹配，实际 {found} 处；"
                           "请重新确认锚点文本", tool="replace_text")
        new_content = content.replace(old, new, count if count >= 0 else found)
        r = self.write(path, new_content, dry_run=dry_run, preview=preview,
                       idempotency_key=idempotency_key)
        r["occurrences"] = found if count < 0 else min(found, count)
        r["diff"] = self._unified_diff(content, new_content, path)
        return r

    def write(self, path: str, content: str, *, dry_run: bool = False, preview: bool = True,
              idempotency_key: Optional[str] = None, retries: int = 2) -> dict:
        """整份覆盖（upsert）。文件存在就自动带 revision，不存在则直接新建。
        返回 {"preview", "result", "revision", "ok"}。"""
        path = _rel(path)
        base_key = idempotency_key or _new_key("write")
        try:
            rev: Optional[str] = self.revision(path)   # 一次读取同时解决 exists+revision
        except MCPError as e:
            if not _is_not_found(e):
                raise
            rev = None
        for attempt in range(retries + 1):
            change: Dict[str, Any] = {"action": "write", "path": path, "content": content}
            if rev:
                change["revision"] = rev
            try:
                pre = None
                if preview and not dry_run:
                    pre = self.apply_changes([change], dry_run=True,
                                             idempotency_key=f"{base_key}:dry{attempt}")
                if dry_run:
                    return {"preview": self.apply_changes([change], dry_run=True,
                                                          idempotency_key=f"{base_key}:dry{attempt}"),
                            "result": None, "revision": rev, "ok": True}
                res = self.apply_changes([change], dry_run=False,
                                         idempotency_key=f"{base_key}:apply{attempt}")
                files = res.get("affected_files") or []
                return {"preview": pre, "result": res,
                        "revision": files[0].get("revision") if files else None, "ok": True}
            except RevisionMismatch:
                if attempt >= retries:
                    raise
                rev = self.revision(path)
        raise MCPError("WRITE_FAILED", "未知失败", tool="apply_changes")

    def create(self, path: str, content: str, *, dry_run: bool = False,
               preview: bool = True, idempotency_key: Optional[str] = None) -> dict:
        """新建文件（要求路径原本不存在；父目录会自动创建）。先 dry_run 预览再提交。"""
        change = {"action": "create", "path": _rel(path), "content": content}
        return self._dry_then_apply([change], dry_run=dry_run, preview=preview,
                                    idempotency_key=idempotency_key, prefix="create")

    def delete(self, path: str, *, dry_run: bool = False, preview: bool = True,
               idempotency_key: Optional[str] = None) -> dict:
        """删除文件（不能删目录）。自动带当前 revision，先预览再提交。"""
        change = {"action": "delete", "path": _rel(path), "revision": self.revision(path)}
        return self._dry_then_apply([change], dry_run=dry_run, preview=preview,
                                    idempotency_key=idempotency_key, prefix="delete")

    def move(self, path: str, destination: str, *, dry_run: bool = False,
             preview: bool = True, idempotency_key: Optional[str] = None) -> dict:
        """移动/重命名（目标必须不存在）。"""
        change = {"action": "move", "path": _rel(path), "destination": _rel(destination),
                  "revision": self.revision(path)}
        return self._dry_then_apply([change], dry_run=dry_run, preview=preview,
                                    idempotency_key=idempotency_key, prefix="move")

    def copy(self, path: str, destination: str, *, dry_run: bool = False,
             preview: bool = True, idempotency_key: Optional[str] = None) -> dict:
        """复制文件（目标必须不存在）。"""
        change = {"action": "copy", "path": _rel(path), "destination": _rel(destination),
                  "revision": self.revision(path)}
        return self._dry_then_apply([change], dry_run=dry_run, preview=preview,
                                    idempotency_key=idempotency_key, prefix="copy")

    def _dry_then_apply(self, changes: Sequence[dict], *, dry_run: bool, preview: bool,
                        idempotency_key: Optional[str], prefix: str) -> dict:
        base_key = idempotency_key or _new_key(prefix)
        pre = self.apply_changes(changes, dry_run=True, idempotency_key=f"{base_key}:dry") \
            if (preview or dry_run) else None
        if dry_run:
            return {"preview": pre, "result": None, "ok": True}
        res = self.apply_changes(changes, dry_run=False, idempotency_key=f"{base_key}:apply")
        files = res.get("affected_files") or []
        return {"preview": pre, "result": res, "ok": True,
                "revision": files[0].get("revision") if files else None}

    def patch(self, patch: str, *, dry_run: bool = False, preview: bool = True,
              idempotency_key: Optional[str] = None) -> dict:
        """上下文锚点补丁：先 dry_run 预览再提交，两次用不同 idempotency_key。"""
        base_key = idempotency_key or _new_key("patch")
        pre = self.apply_patch(patch, dry_run=True, idempotency_key=f"{base_key}:dry") \
            if (preview or dry_run) else None
        if dry_run:
            return {"preview": pre, "result": None, "ok": True}
        res = self.apply_patch(patch, dry_run=False, idempotency_key=f"{base_key}:apply")
        return {"preview": pre, "result": res, "ok": True,
                "affected_files": res.get("affected_files")}

    def patch_file(self, path: str, body: str, *, dry_run: bool = False,
                   preview: bool = True, idempotency_key: Optional[str] = None) -> dict:
        """只给单个文件的 hunk 正文，自动包上 V4A 信封。"""
        envelope = f"*** Begin Patch\n*** Update File: {_rel(path)}\n{body.rstrip(chr(10))}\n*** End Patch"
        return self.patch(envelope, dry_run=dry_run, preview=preview,
                          idempotency_key=idempotency_key)

    def edit_many(self, changes: Sequence[dict], *, dry_run: bool = False,
                  preview: bool = True, idempotency_key: Optional[str] = None,
                  strip_trailing_newline: bool = True, auto_revision: bool = True) -> dict:
        """
        多文件原子改动（一次 apply_changes，全部成功或全部失败）。
        auto_revision=True 时自动为 edit/delete/move/copy/已存在的 write 补 revision，
        并统一把 path/destination 规范化为相对路径；create 不带 revision。
        同一 path 只能出现一次；单文件多处修改请合并进该文件的 edits 数组。
        """
        norm = []
        for c in changes:
            c = dict(c)
            c["path"] = _rel(c["path"])
            if c.get("destination"):
                c["destination"] = _rel(c["destination"])
            if c.get("edits"):
                c["edits"] = self._normalize_edits(c["edits"], strip_trailing_newline)
            action = c.get("action")
            if auto_revision and "revision" not in c:
                if action in ("edit", "delete", "move", "copy"):
                    c["revision"] = self.revision(c["path"])
                elif action == "write":
                    try:
                        c["revision"] = self.revision(c["path"])
                    except MCPError as e:
                        if not _is_not_found(e):
                            raise   # 不存在 → 新建，无需 revision
            norm.append(c)
        base_key = idempotency_key or _new_key("multi")
        pre = self.apply_changes(norm, dry_run=True, idempotency_key=f"{base_key}:dry") \
            if (preview or dry_run) else None
        if dry_run:
            return {"preview": pre, "result": None, "ok": True}
        res = self.apply_changes(norm, dry_run=False, idempotency_key=f"{base_key}:apply")
        return {"preview": pre, "result": res, "ok": True,
                "affected_files": res.get("affected_files")}

    # ---------------- 本地 <-> 工作区（仅 UTF-8 文本；图片用 view_image） ---------------- #
    def upload(self, local_path: str, remote_path: str, **kw) -> dict:
        with open(local_path, "r", encoding="utf-8") as f:
            return self.write(remote_path, f.read(), **kw)

    def download(self, remote_path: str, local_path: str) -> str:
        d = self.read_all(remote_path)
        with open(local_path, "w", encoding="utf-8") as f:
            f.write(d["content"])
        return local_path

    # ======================================================================= #
    # 六、端到端自检（python3 coding_mcp.py selftest）
    # ======================================================================= #
    def selftest(self, *, keep_scratch: bool = False) -> dict:
        """对真实服务端跑一轮端到端检查：握手/读/写/改/补丁/幂等/冲突/执行/清理。
        全部用临时scratch文件，结束后删除。返回 {"ok", "checks":[{name,ok,detail}]}。"""
        import tempfile

        A = "tmp_cmcp_selftest_a.txt"
        B = "tmp_cmcp_selftest_b.txt"
        checks: List[dict] = []

        def check(name, fn):
            try:
                detail = fn()
                if not isinstance(detail, str):
                    detail = json.dumps(detail, ensure_ascii=False)
                checks.append({"name": name, "ok": True, "detail": detail[:300]})
            except Exception as e:
                checks.append({"name": name, "ok": False,
                               "detail": f"{type(e).__name__}: {e}"[:500]})

        def c_init():
            r = self.initialize()
            si = r.get("serverInfo", {})
            assert r.get("protocolVersion"), "no protocolVersion"
            return f"{si.get('name')} v{si.get('version')} proto={r.get('protocolVersion')}"

        def c_tools():
            names = set(self.tool_names())
            need = {"read_file", "apply_changes", "apply_patch", "exec_command"}
            assert need <= names, f"缺少核心工具: {need - names}"
            return f"{len(names)} tools"

        def c_info():
            return "workspace=" + str(self.server_info().get("workspace"))

        def c_write_read():
            sample = "第一行\nsecond line\n\n第四行\n"
            self.write(A, sample)
            got = self.read_file(A)["content"]
            assert got == sample, f"roundtrip mismatch: {got!r}"
            return "utf8 roundtrip ok"

        def c_read_all():
            big = ("0123456789abcdef" * 25 + "\n") * 80   # ~32KB，强制多块
            self.write(A, big)
            d = self.read_all(A, chunk_bytes=4000)
            assert d["content"] == big, "paged read_all mismatch"
            assert d["chunks"] > 1, "expected multiple chunks"
            return f"{d['chunks']} chunks, {len(big)} chars identical"

        def c_edit():
            self.write(A, "l1\nl2\nl3\nl4\n")
            r = self.edit(A, [{"op": "replace", "start_line": 2, "end_line": 3,
                               "content": "L2\nL3"}])
            got = self.read_file(A)["content"]
            assert got == "l1\nL2\nL3\nl4\n", f"edit mismatch: {got!r}"
            assert r.get("diff"), "no local diff returned"
            return "replace 2-3 ok, diff returned"

        def c_insert_delete():
            self.insert_after(A, 0, "HEAD")
            self.delete_lines(A, 2, 2)
            got = self.read_file(A)["content"]
            assert got == "HEAD\nL2\nL3\nl4\n", f"insert/delete mismatch: {got!r}"
            return "insert_after(0) + delete_lines ok"

        def c_patch():
            self.write(A, "a\nb\nc\n")
            r = self.patch_file(A, "@@\n-a\n+A\n b\n-c\n+C\n")
            got = self.read_file(A)["content"]
            assert got == "A\nb\nC\n", f"patch mismatch: {got!r}"
            mq = (r.get("result") or {}).get("affected_files", [{}])[0].get("match_quality")
            return f"V4A patch ok, match_quality={mq}"

        def c_dry_run():
            before = self.read_file(A)["content"]
            self.edit(A, [{"op": "replace", "start_line": 1, "end_line": 1,
                           "content": "DRY"}], dry_run=True)
            assert self.read_file(A)["content"] == before, "dry_run mutated file!"
            return "dry_run leaves file untouched"

        def c_idem():
            self.write(A, "x\n")
            rev0 = self.revision(A)
            args = [{"action": "write", "path": A, "content": "idem\n", "revision": rev0}]
            key = _new_key("selftest-idem")
            r1 = self.apply_changes(args, idempotency_key=key)
            r2 = self.apply_changes(args, idempotency_key=key)  # 完全同参 → 重放
            assert r1.get("ok") and r2.get("idempotent_replay"), "no idempotent replay"
            return "identical-args replay ok"

        def c_stale_refused():
            self.write(A, "p1\np2\n")
            stale = self.revision(A)
            self.write(A, "p1\np2-changed\n")
            try:
                self.edit(A, [{"op": "replace", "start_line": 2, "end_line": 2,
                               "content": "X"}], revision=stale)
            except RevisionMismatch:
                return "stale pinned revision refused (no blind retry)"
            raise AssertionError("stale pinned revision was NOT refused")

        def c_run_basic():
            r = self.run("echo out; echo err 1>&2; exit 3")
            assert r["exit_code"] == 3 and r["stdout"] == "out\n" and r["stderr"] == "err\n", \
                f"run basic mismatch: {r}"
            return "exit_code/stdout/stderr ok"

        def c_run_pipefail():
            r = self.run("false | echo piped")
            assert r["exit_code"] == 1, f"pipefail exit_code={r['exit_code']} (期望 1)"
            assert r["stdout"] == "piped\n", f"stdout={r['stdout']!r}"
            return f"bash wrap ok: {r['cmd'][:60]}"

        def c_run_poll():
            r = self.run("for i in 1 2 3; do echo t$i; sleep 1; done", poll_ms=800)
            assert r["exit_code"] == 0 and r["stdout"] == "t1\nt2\nt3\n", \
                f"poll mismatch: {r['stdout']!r} polls={r['polls']}"
            return f"background polled {r['polls']}x, output complete"

        def c_run_big():
            r = self.run("python3 -c \"print('x'*150000)\"")
            assert len(r["stdout"]) == 150001, f"big output len={len(r['stdout'])}"
            return "150KB stdout complete"

        def c_replace_text():
            self.write(A, "foo bar foo\n")
            r = self.replace_text(A, "foo", "baz", expected_occurrences=2)
            got = self.read_file(A)["content"]
            assert got == "baz bar baz\n" and r["occurrences"] == 2, f"got={got!r}"
            return "2 occurrences replaced"

        def c_append():
            self.append(A, "tail")
            got = self.read_file(A)["content"]
            assert got.endswith("tail\n"), f"append mismatch: {got!r}"
            return "append ok"

        def c_upload_download():
            payload = "upload 测试\nline2\n"
            with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False,
                                             encoding="utf-8") as f:
                f.write(payload)
                lp = f.name
            try:
                self.upload(lp, B)
                lp2 = lp + ".down"
                self.download(B, lp2)
                with open(lp2, encoding="utf-8") as f:
                    assert f.read() == payload, "download mismatch"
                os.unlink(lp2)
            finally:
                os.unlink(lp)
            return "upload/download roundtrip ok"

        def c_edit_many():
            self.write(A, "m1\nm2\n")
            self.write(B, "n1\nn2\n")
            r = self.edit_many([
                {"action": "edit", "path": A,
                 "edits": [{"op": "replace", "start_line": 1, "end_line": 1, "content": "M1"}]},
                {"action": "edit", "path": B,
                 "edits": [{"op": "replace", "start_line": 2, "end_line": 2, "content": "N2"}]},
            ])   # 不带 revision，靠 auto_revision
            assert r.get("ok"), "edit_many failed"
            assert self.read_file(A)["content"] == "M1\nm2\n"
            assert self.read_file(B)["content"] == "n1\nN2\n"
            return "auto revision + atomic multi-file ok"

        def c_cleanup():
            for p in (A, B):
                if self.exists(p):
                    self.delete(p)
                assert not self.exists(p), f"{p} still exists"
            return "scratch files removed"

        try:
            check("initialize", c_init)
            check("tools/list", c_tools)
            check("server_info", c_info)
            check("write+read roundtrip", c_write_read)
            check("read_all paging integrity", c_read_all)
            check("edit replace_lines", c_edit)
            check("insert/delete lines", c_insert_delete)
            check("apply_patch V4A", c_patch)
            check("dry_run non-mutation", c_dry_run)
            check("idempotent replay", c_idem)
            check("stale revision refused", c_stale_refused)
            check("run exit/stdout/stderr", c_run_basic)
            check("run pipefail (bash wrap)", c_run_pipefail)
            check("run background polling", c_run_poll)
            check("run large output", c_run_big)
            check("replace_text", c_replace_text)
            check("append", c_append)
            check("upload/download", c_upload_download)
            check("edit_many auto revision", c_edit_many)
        finally:
            if not keep_scratch:
                check("cleanup", c_cleanup)
        ok = all(c["ok"] for c in checks)
        return {"ok": ok, "passed": sum(c["ok"] for c in checks),
                "total": len(checks), "checks": checks}


# --------------------------------------------------------------------------- #
# 命令行
# --------------------------------------------------------------------------- #
def _print(obj: Any, as_json: bool = False):
    if as_json:
        print(json.dumps(obj, ensure_ascii=False, indent=2))
    elif isinstance(obj, str):
        print(obj)
    elif isinstance(obj, dict) and set(obj.keys()) <= {"ok", "text"}:
        print(obj.get("text", ""))
    else:
        print(json.dumps(obj, ensure_ascii=False, indent=2))


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="coding_mcp.py",
        description="Coding Tools MCP 直连客户端（url + token 即可读写工作区）")
    p.add_argument("--url", default=None, help="MCP endpoint，默认取 env CODING_MCP_URL")
    p.add_argument("--token", default=None, help="access token，默认取 env CODING_MCP_TOKEN")
    p.add_argument("--timeout", type=float, default=180.0)
    p.add_argument("--json", action="store_true", help="输出原始 JSON")
    p.add_argument("-v", "--verbose", action="store_true")
    sub = p.add_subparsers(dest="subcmd", required=True)  # 勿与 run 的位置参数 cmd 同名冲突

    sub.add_parser("init", help="initialize 握手")
    sub.add_parser("info", help="server_info + 环境检查")
    sub.add_parser("tools", help="tools/list（名字+必填参数）")
    sub.add_parser("schema", help="看某个工具的完整 schema").add_argument("name")
    sub.add_parser("selftest", help="端到端自检（临时文件，自动清理）")

    q = sub.add_parser("docs", help="生成全部工具的 Markdown 速查文档")
    q.add_argument("--out", help="写到本地文件（缺省打印到 stdout）")

    q = sub.add_parser("ls", help="列目录")
    q.add_argument("path", nargs="?", default=".")
    q.add_argument("--recursive", action="store_true")
    q.add_argument("--max-entries", type=int)

    q = sub.add_parser("files", help="按 glob 找文件")
    q.add_argument("glob")
    q.add_argument("--max-results", type=int)

    q = sub.add_parser("read", help="读文件")
    q.add_argument("path")
    q.add_argument("--start", type=int)
    q.add_argument("--end", type=int)
    q.add_argument("--all", action="store_true", help="自动翻页读完整文件")
    q.add_argument("--numbered", action="store_true", help="带行号输出")

    q = sub.add_parser("grep", help="全文搜索")
    q.add_argument("query")
    q.add_argument("--path")
    q.add_argument("--regex", action="store_true")
    q.add_argument("--glob")
    q.add_argument("--context", type=int)
    q.add_argument("--max-results", type=int)

    q = sub.add_parser("run", help="跑命令并等结束（只用于验证，不要用来改文件）")
    q.add_argument("cmd")
    q.add_argument("--workdir", default=".")
    q.add_argument("--timeout", type=float, default=300.0, dest="run_timeout")
    q.add_argument("--env", help='JSON，如 {"yxltck":"..."}')
    q.add_argument("--no-pipefail", action="store_true")
    q.add_argument("--check", action="store_true")
    q.add_argument("--poll-ms", type=int, default=15000)

    q = sub.add_parser("write", help="整份覆盖/新建文件")
    q.add_argument("path")
    q.add_argument("--from-file", help="本地文件作为内容")
    q.add_argument("--content")
    q.add_argument("--dry-run", action="store_true")

    q = sub.add_parser("edit", help="按行号替换/删除")
    q.add_argument("path")
    q.add_argument("--start", type=int, required=True)
    q.add_argument("--end", type=int)
    q.add_argument("--from-file", help="本地文件作为新内容")
    q.add_argument("--content", default=None)
    q.add_argument("--delete", action="store_true", help="删除该行区间")
    q.add_argument("--revision", help="钉住 revision（过期立即报错，不盲重试）")
    q.add_argument("--dry-run", action="store_true")

    q = sub.add_parser("insert", help="在某行后/前插入")
    q.add_argument("path")
    q.add_argument("--line", type=int, required=True)
    q.add_argument("--before", action="store_true")
    q.add_argument("--from-file")
    q.add_argument("--content", default=None)
    q.add_argument("--dry-run", action="store_true")

    q = sub.add_parser("append", help="追加到文件末尾")
    q.add_argument("path")
    q.add_argument("--from-file")
    q.add_argument("--content", default=None)
    q.add_argument("--dry-run", action="store_true")

    q = sub.add_parser("replace-text", help="按文本锚点替换（读全文→本地替换→带 revision 写回）")
    q.add_argument("path")
    q.add_argument("--old", required=True)
    q.add_argument("--new", required=True)
    q.add_argument("--count", type=int, default=-1, help="最多替换几处，-1 全部")
    q.add_argument("--expected", type=int, help="期望匹配数，不符立即报错")
    q.add_argument("--dry-run", action="store_true")

    q = sub.add_parser("patch", help="V4A 上下文补丁")
    q.add_argument("--from-file", required=True)
    q.add_argument("--dry-run", action="store_true")

    q = sub.add_parser("rm", help="删除工作区文件（不能删目录）")
    q.add_argument("path")
    q.add_argument("--dry-run", action="store_true")

    q = sub.add_parser("mv", help="移动/重命名（目标必须不存在）")
    q.add_argument("src")
    q.add_argument("dst")
    q.add_argument("--dry-run", action="store_true")

    q = sub.add_parser("cp", help="复制文件（目标必须不存在）")
    q.add_argument("src")
    q.add_argument("dst")
    q.add_argument("--dry-run", action="store_true")

    q = sub.add_parser("diff", help="git diff（非 git 仓库为服务端 fallback）")
    q.add_argument("paths", nargs="*")

    q = sub.add_parser("status", help="git status")

    q = sub.add_parser("image", help="取工作区图片存到本地")
    q.add_argument("path")
    q.add_argument("--save-to", required=True)

    q = sub.add_parser("upload", help="本地文件 -> 工作区")
    q.add_argument("local")
    q.add_argument("remote")

    q = sub.add_parser("download", help="工作区 -> 本地文件")
    q.add_argument("remote")
    q.add_argument("local")

    q = sub.add_parser("call", help="任意工具直调")
    q.add_argument("name")
    q.add_argument("--args", default="{}", help="JSON 参数")

    # 全局开关也允许放在子命令之后（AI 常把 --json 追加在末尾）；
    # default=SUPPRESS 保证子命令未显式给出时不覆盖顶层解析结果。
    for sp in sub.choices.values():
        sp.add_argument("--json", action="store_true", default=argparse.SUPPRESS,
                        help=argparse.SUPPRESS)
        sp.add_argument("--url", default=argparse.SUPPRESS, help=argparse.SUPPRESS)
        sp.add_argument("--token", default=argparse.SUPPRESS, help=argparse.SUPPRESS)
        sp.add_argument("-v", "--verbose", action="store_true",
                        default=argparse.SUPPRESS, help=argparse.SUPPRESS)
    return p


def main(argv: Optional[Sequence[str]] = None) -> int:
    a = build_parser().parse_args(argv)
    try:
        mcp = CodingMCP(a.url, a.token, timeout=a.timeout, verbose=a.verbose)
        c = a.subcmd
        if c == "init":
            _print(mcp.initialize(), a.json)
        elif c == "info":
            _print({"server": mcp.server_info(), "exec_env": mcp.check_exec_environment()}, a.json)
        elif c == "tools":
            rows = [{"name": t["name"],
                     "required": t.get("inputSchema", {}).get("required", []),
                     "params": list(t.get("inputSchema", {}).get("properties", {}))}
                    for t in mcp.tools()]
            _print(rows, a.json)
        elif c == "schema":
            _print(mcp.tool_schema(a.name), True)
        elif c == "selftest":
            r = mcp.selftest()
            if a.json:
                _print(r, True)
            else:
                for ck in r["checks"]:
                    print(f"{'PASS' if ck['ok'] else 'FAIL'}  {ck['name']}: {ck['detail']}")
                print(f"== selftest: {r['passed']}/{r['total']} passed ==")
            return 0 if r["ok"] else 1
        elif c == "docs":
            mcp.ensure_ready()
            doc = mcp.tools_doc()
            if a.out:
                with open(a.out, "w", encoding="utf-8") as f:
                    f.write(doc)
                print("saved:", a.out)
            else:
                print(doc)
        elif c == "ls":
            _print(mcp.list_dir(a.path, recursive=a.recursive, max_entries=a.max_entries), a.json)
        elif c == "files":
            _print(mcp.list_files(a.glob, max_results=a.max_results), a.json)
        elif c == "read":
            if a.numbered:
                print(mcp.read_numbered(a.path, start_line=a.start, end_line=a.end))
            elif a.all:
                d = mcp.read_all(a.path)
                if a.json:
                    _print(d, True)
                else:
                    print(f"[{a.path} total_lines={d['total_lines']} revision={d['revision']}]")
                    sys.stdout.write(d["content"])
            else:
                d = mcp.read_file(a.path, a.start, a.end)
                if a.json:
                    _print(d, True)
                else:
                    print(f"[{a.path} lines {d['start_line']}-{d['end_line']} of "
                          f"{d['total_lines']} revision={d['revision']}]")
                    sys.stdout.write(d["content"])
                    if d.get("truncated"):
                        print(f"\n[TRUNCATED by {d.get('truncated_by')}; "
                              f"next_start_line={d.get('next_start_line')}；"
                              "继续读请带 --start，或用 --all]", file=sys.stderr)
        elif c == "grep":
            _print(mcp.search_text(a.query, path=a.path, regex=a.regex, glob=a.glob,
                                   context_lines=a.context, max_results=a.max_results), a.json)
        elif c == "run":
            env = json.loads(a.env) if a.env else None
            r = mcp.run(a.cmd, workdir=a.workdir, env=env, timeout=a.run_timeout,
                        pipefail=not a.no_pipefail, check=a.check, poll_ms=a.poll_ms)
            if a.json:
                _print(r, True)
            else:
                print(f"status={r['status']} exit_code={r['exit_code']} "
                      f"elapsed_ms={r['elapsed_ms']} timed_out={r['timed_out']}")
                for w in r.get("warnings", []):
                    print(f"WARNING: {w}", file=sys.stderr)
                if r["stdout"]:
                    print("--- stdout ---")
                    sys.stdout.write(r["stdout"])
                if r["stderr"]:
                    print("--- stderr ---")
                    sys.stdout.write(r["stderr"])
            return 0 if r["ok"] else 1
        elif c in ("write", "edit", "insert", "append", "replace-text"):
            content = getattr(a, "content", None)
            if getattr(a, "from_file", None):
                with open(a.from_file, "r", encoding="utf-8") as f:
                    content = f.read()
            if c == "write":
                if content is None:
                    raise SystemExit("write 需要 --content 或 --from-file")
                _print(mcp.write(a.path, content, dry_run=a.dry_run), a.json)
            elif c == "edit":
                if a.delete:
                    _print(mcp.delete_lines(a.path, a.start, a.end, dry_run=a.dry_run,
                                            revision=a.revision), a.json)
                else:
                    if content is None:
                        raise SystemExit("edit 需要 --content 或 --from-file（或 --delete）")
                    _print(mcp.replace_lines(a.path, a.start, a.end or a.start, content,
                                             dry_run=a.dry_run, revision=a.revision), a.json)
            elif c == "insert":
                if content is None:
                    raise SystemExit("insert 需要 --content 或 --from-file")
                fn = mcp.insert_before if a.before else mcp.insert_after
                _print(fn(a.path, a.line, content, dry_run=a.dry_run), a.json)
            elif c == "append":
                if content is None:
                    raise SystemExit("append 需要 --content 或 --from-file")
                _print(mcp.append(a.path, content, dry_run=a.dry_run), a.json)
            else:
                _print(mcp.replace_text(a.path, a.old, a.new, count=a.count,
                                        expected_occurrences=a.expected,
                                        dry_run=a.dry_run), a.json)
        elif c == "patch":
            with open(a.from_file, "r", encoding="utf-8") as f:
                _print(mcp.patch(f.read(), dry_run=a.dry_run), a.json)
        elif c == "rm":
            _print(mcp.delete(a.path, dry_run=a.dry_run), a.json)
        elif c == "mv":
            _print(mcp.move(a.src, a.dst, dry_run=a.dry_run), a.json)
        elif c == "cp":
            _print(mcp.copy(a.src, a.dst, dry_run=a.dry_run), a.json)
        elif c == "diff":
            print(mcp.diff(a.paths or None))
        elif c == "status":
            _print(mcp.git_status(), a.json)
        elif c == "image":
            _print(mcp.view_image(a.path, save_to=a.save_to), a.json)
        elif c == "upload":
            _print(mcp.upload(a.local, a.remote), a.json)
        elif c == "download":
            print("saved:", mcp.download(a.remote, a.local))
        elif c == "call":
            _print(mcp.call(a.name, json.loads(a.args)), True)
        else:
            raise SystemExit(f"未知子命令 {c}")
        return 0
    except (MCPError, TransportError, ValueError) as e:
        print(f"ERROR {type(e).__name__}: {e}", file=sys.stderr)
        if isinstance(e, MCPError) and e.text:
            print(e.text, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
