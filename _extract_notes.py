import json
path = r"C:\Users\11\.cursor\projects\d-1spbfq-video-player-app\agent-transcripts\58dc0ac0-6335-403c-9946-fb880080194d\58dc0ac0-6335-403c-9946-fb880080194d.jsonl"
out = r"D:\1spbfq\video_player_app\_yt_audio_task_notes.txt"
chunks = []
with open(path, "r", encoding="utf-8") as f:
    for i, line in enumerate(f):
        o = json.loads(line)
        role = o.get("role")
        for c in o.get("message", {}).get("content", []):
            if not isinstance(c, dict):
                continue
            if c.get("type") == "text":
                t = c.get("text") or ""
                chunks.append("--- %d %s ---\n%s\n" % (i, role, t[:3000]))
            elif c.get("type") == "tool_use":
                chunks.append("--- %d tool %s ---\n%s\n" % (i, c.get("name"), str(c.get("input", {}))[:900]))
with open(out, "w", encoding="utf-8") as w:
    w.write("\n".join(chunks))
print("ok", len(chunks))
