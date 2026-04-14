#Export the model:
from ultralytics import YOLO
model = YOLO('yolov8n.pt')
model.export(format='tflite', half=True)
