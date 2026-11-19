# JamalsGPT (JGPG) — জিরো বাজেট গাইড

কোনো টাকা, Android Studio বা Flutter ইনস্টল লাগবে না। APK বানাবে GitHub-এর ফ্রি সার্ভার।

## ১. APK বানানো (একবারের কাজ)
1. https://github.com এ ফ্রি অ্যাকাউন্ট খুলুন।
2. New repository → নাম `jamalsgpt` → Public → Create।
3. "uploading an existing file" চাপুন। এই ZIP আনজিপ করে **ভেতরের সব ফাইল ও ফোল্ডার (লুকানো `.github` সহ)** টেনে এনে ছাড়ুন → Commit changes।
4. উপরের **Actions** ট্যাব → "Build APK" → **Run workflow**।
5. ৫-১০ মিনিট পর সবুজ টিক এলে রান খুলুন → নিচে **Artifacts** থেকে `JamalsGPT-apk` ডাউনলোড করুন।
6. ZIP আনজিপ করলে `JamalsGPT.apk` পাবেন। ফোনে পাঠিয়ে ইনস্টল করুন ("Unknown sources" অনুমতি দিন)।

বিল্ড ফেইল করলে লাল রানের লগ কপি করে আমাকে দিন, ঠিক করে দেব।

## ২. ফ্রি API Key
- **Gemini (সুপারিশ):** https://aistudio.google.com/apikey → Create API key।
- **OpenRouter:** https://openrouter.ai/keys → key বানান; মডেল ঘরে `:free` শেষ হওয়া মডেল দিন।

## ৩. অ্যাপে key বসানো
অ্যাপ খুলুন → ☰ মেনু → সেটিংস → প্রোভাইডার বাছুন → API Key পেস্ট → সংরক্ষণ।
Key শুধু আপনার ফোনে থাকে, APK-তে নেই।

## ৪. মুছে ফেলা
ফোন থেকে অ্যাপ আনইনস্টল করুন। GitHub repository ডিলিট করলে বিল্ডও মুছে যাবে।

## এখন যা আছে / নেই
আছে: স্ট্রিমিং চ্যাট, চ্যাট হিস্ট্রি, বাংলা/ইংরেজি, Gemini ও OpenRouter, মডেল বদল, ডার্ক UI।
নেই (পরের ধাপ): ছবি, ভিডিও, কোডিং স্টুডিও, ওয়েবসাইট বিল্ডার, রিসার্চ, PDF।
