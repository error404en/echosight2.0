# This is a placeholder for the YOLOv8n TFLite model.
# 
# To get the actual model file:
# 1. Install ultralytics: pip install ultralytics
# 2. Export the model:
#    from ultralytics import YOLO
#    model = YOLO('yolov8n.pt')
#    model.export(format='tflite', half=True)
# 3. Copy the generated yolov8n_float16.tflite to this directory
#    and rename it to yolov8n.tflite
#
# Model specs:
# - Input: 640x640x3 (RGB, float32)
# - Output: [1, 84, 8400] (bounding boxes + 80 class scores)
# - Size: ~6MB (float16)
