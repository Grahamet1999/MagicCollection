# The google_mlkit_text_recognition plugin references every script's
# recognizer class, but we only bundle the Latin model. R8 treats the other
# scripts' classes as missing — tell it they're intentionally absent.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
