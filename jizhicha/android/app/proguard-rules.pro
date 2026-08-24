# flutter_onnxruntime uses ONNX Runtime's Java/JNI bridge during Android OCR.
# Keep the runtime classes when a local/release build enables R8 shrinking;
# otherwise some devices fail while creating the OCR session.
-keep class ai.onnxruntime.** { *; }
