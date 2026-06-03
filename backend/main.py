from fastapi import FastAPI, WebSocket, WebSocketDisconnect

app = FastAPI()

clients = {}

@app.websocket("/ws/{user_id}")
async def websocket_endpoint(websocket: WebSocket, user_id: str):
    await websocket.accept()

    clients[user_id] = websocket
    print(f"{user_id} connected")

    try:
        while True:
            message = await websocket.receive_text()

            parts = message.split("|", 1)

            if len(parts) != 2:
                continue

            target = parts[0]
            data = parts[1]

            if target in clients:
                await clients[target].send_text(
                    f"{user_id}|{data}"
                )
            else:
                await websocket.send_text(
                    'SERVER|{"type":"user_not_found"}'
                )

    except WebSocketDisconnect:
        clients.pop(user_id, None)
        print(f"{user_id} disconnected")