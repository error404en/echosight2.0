import os
import io
import base64
import face_recognition
from PIL import Image
import numpy as np

# Cache of known face encodings
KNOWN_FACES_DIR = "known_faces"
known_encodings = []
known_names = []

def init_face_engine():
    """Load known faces into memory to avoid reloading during streams."""
    global known_encodings, known_names
    
    if not os.path.exists(KNOWN_FACES_DIR):
        os.makedirs(KNOWN_FACES_DIR)
        print(f"[WARN] Created {KNOWN_FACES_DIR} directory. Drop photos here to enable Face ID.")
        return

    loaded = 0
    for file in os.listdir(KNOWN_FACES_DIR):
        if file.endswith((".jpg", ".jpeg", ".png")):
            name = os.path.splitext(file)[0].title() # e.g. "rahul.jpg" -> "Rahul"
            path = os.path.join(KNOWN_FACES_DIR, file)
            
            try:
                # Load image and compute encoding
                img = face_recognition.load_image_file(path)
                encodings = face_recognition.face_encodings(img)
                
                if encodings:
                    known_encodings.append(encodings[0])
                    known_names.append(name)
                    loaded += 1
            except Exception as e:
                print(f"[ERR] Failed to load face {file}: {e}")
                
    if loaded > 0:
        print(f"[OK] Face Recognition loaded {loaded} known identities")

def detect_known_faces(image_base64: str) -> list[str]:
    """
    Decodes the camera frame, highly downscales it for CPU efficiency,
    and returns a list of names detected.
    """
    if not known_encodings or not known_names:
        return []
        
    try:
        # Decode Base64 to image
        image_bytes = base64.b64decode(image_base64)
        pil_img = Image.open(io.BytesIO(image_bytes))
        
        # Aggressive downscale for CPU speed (max 320x320)
        pil_img.thumbnail((320, 320))
        
        # Convert to numpy array (RGB)
        rgb_frame = np.array(pil_img.convert("RGB"))
        
        # Find faces in the resized frame
        face_locations = face_recognition.face_locations(rgb_frame, model="hog")
        if not face_locations:
            return []
            
        # Extract encodings for detected faces
        face_encodings = face_recognition.face_encodings(rgb_frame, face_locations)
        
        detected_names = []
        for face_encoding in face_encodings:
            # Compare to known faces
            matches = face_recognition.compare_faces(known_encodings, face_encoding, tolerance=0.55)
            if any(matches):
                # Find the best match
                face_distances = face_recognition.face_distance(known_encodings, face_encoding)
                best_match_index = np.argmin(face_distances)
                if matches[best_match_index]:
                    detected_names.append(known_names[best_match_index])
                    
        return list(set(detected_names))
    except Exception as e:
        print(f"[ERR] Face detection failed: {e}")
        return []
