"""A stand-in for AssemblyAI's streaming API (v3 protocol subset), for tests/stream.sh.

Accepts one WebSocket session at a time on 127.0.0.1:PORT. Checks the Authorization
header, sends Begin, a partial Turn once audio arrives, and on ForceEndpoint a final
Turn saying how much audio it received and which keyterms it was given. Writes a
line per session to LOG. usage: python3 fake_assemblyai.py PORT LOG [MODE]
MODE: ok (default) | reject (refuse the key) | silent (never finalizes a turn)
      | late (no partial; the final turn comes 0.4 s after ForceEndpoint, like a short
        phrase the server hasn't caught up with) | empty (final turn with no text)
      | tail (a first turn is final after 300 ms of audio; the last words come only
        0.4 s after ForceEndpoint, like "it works though" said just before stop)
Turns carry word timings ("words" with "end" in audio ms), like the real API.
"""
import base64, hashlib, json, socket, sys, threading, time, urllib.parse

PORT, LOG = int(sys.argv[1]), sys.argv[2]
MODE = sys.argv[3] if len(sys.argv) > 3 else "ok"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def read_exact(conn, n, buf):
    while len(buf[0]) < n:
        d = conn.recv(65536)
        if not d:
            raise ConnectionError
        buf[0] += d
    out, buf[0] = buf[0][:n], buf[0][n:]
    return out


def recv_frame(conn, buf):
    b0, b1 = read_exact(conn, 2, buf)
    n = b1 & 0x7F
    if n == 126:
        n = int.from_bytes(read_exact(conn, 2, buf), "big")
    elif n == 127:
        n = int.from_bytes(read_exact(conn, 8, buf), "big")
    mask = read_exact(conn, 4, buf)
    data = bytes(c ^ mask[i % 4] for i, c in enumerate(read_exact(conn, n, buf)))
    return b0 & 0x0F, data


def send_frame(conn, data, opcode=0x1):
    n = len(data)
    head = bytes([0x80 | opcode]) + (bytes([n]) if n < 126 else bytes([126]) + n.to_bytes(2, "big"))
    conn.sendall(head + data)


def handle(conn):
    buf = [b""]
    while b"\r\n\r\n" not in buf[0]:
        data = conn.recv(4096)
        if not data:
            conn.close(); return
        buf[0] += data
    head, buf[0] = buf[0].split(b"\r\n\r\n", 1)
    lines = head.decode().split("\r\n")
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(lines[0].split()[1]).query)
    hdr = {k.lower(): v.strip() for k, v in (l.split(":", 1) for l in lines[1:])}
    accept = base64.b64encode(hashlib.sha1((hdr["sec-websocket-key"] + GUID).encode()).digest()).decode()
    conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    send = lambda obj: send_frame(conn, json.dumps(obj).encode())
    if MODE == "reject" or hdr.get("authorization") != "test-key":
        send({"type": "Error", "error": "Unauthorized Connection"}); conn.close(); return
    send({"type": "Begin", "id": "fake"})
    audio, partial_sent, first_final = 0, False, False
    words = lambda end: [{"text": "w", "start": max(end - 200, 0), "end": end, "word_is_final": True}]
    terms = json.loads(query.get("keyterms_prompt", ["[]"])[0])
    while True:
        try:
            op, data = recv_frame(conn, buf)
        except (ConnectionError, OSError):
            break
        if op == 0x2:
            audio += len(data)
            if MODE == "tail":
                if not first_final and audio // 32 >= 300:
                    send({"type": "Turn", "end_of_turn": True, "transcript": "First part.",
                          "words": words(audio // 32 - 50)}); first_final = True
            elif not partial_sent and MODE not in ("silent", "late", "empty"):
                send({"type": "Turn", "end_of_turn": False, "transcript": "hello",
                      "words": words(audio // 32)}); partial_sent = True
        elif op == 0x1:
            msg = json.loads(data)
            if msg["type"] == "ForceEndpoint" and MODE == "empty":
                send({"type": "Turn", "end_of_turn": True, "transcript": ""})
            elif msg["type"] == "ForceEndpoint" and MODE != "silent":
                if MODE in ("late", "tail"):
                    time.sleep(0.4)
                text = "it works though." if MODE == "tail" else f"Got {audio // 32} ms; terms {','.join(terms)}."
                send({"type": "Turn", "end_of_turn": True, "transcript": text, "words": words(audio // 32)})
            elif msg["type"] == "Terminate":
                send({"type": "Termination"}); break
        elif op == 0x8:
            break
    with open(LOG, "a") as f:
        f.write(json.dumps({"model": query.get("speech_model", [""])[0], "audio_ms": audio // 32, "terms": terms}) + "\n")
    conn.close()


srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT)); srv.listen()
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
