# Babble

Passive baby activity monitor — native iOS app + Python backend.

Listens for your baby's name or crying → transcribes → speaker-diarizes → asks Gemini what happened → logs events automatically.

## Project Structure

```
babble/
└── ios/
    ├── Babble/          ← Swift/SwiftUI iOS app
    │   ├── App/
    │   ├── Models/
    │   ├── Services/
    │   ├── ViewModels/
    │   ├── Utilities/
    │   └── Views/
    ├── backend/         ← FastAPI backend
    │   ├── main.py
    │   ├── gemini_client.py
    │   ├── diarization.py
    │   └── db.py
    └── README.md        ← setup instructions
```

## Quick Start

```bash
cd ios/backend
pip install -r requirements.txt
uvicorn main:app --reload
```

See [ios/README.md](ios/README.md) for full iOS setup instructions.
