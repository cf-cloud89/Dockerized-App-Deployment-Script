from flask import Flask, jsonify
app = Flask(__name__)

@app.route("/api")
def api():
    return jsonify({"message": "Hello from Chinecherem Udegbunam"})

@app.route("/")
def root():
    return "<h1>Index served from container</h1><p>Try GET /api</p>"

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
