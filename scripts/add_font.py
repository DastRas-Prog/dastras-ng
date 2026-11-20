import os, sys
# Adds MiSans to the app when the font files were uploaded to assets/fonts (otherwise the system font is used).
if not os.path.exists('assets/fonts/MiSans-Regular.ttf'):
    print('MiSans not provided - using the system font')
    sys.exit(0)
s = open('pubspec.yaml', encoding='utf-8').read()
block = "  fonts:\n    - family: MiSans\n      fonts:\n        - asset: assets/fonts/MiSans-Regular.ttf\n"
for name, weight in (('Medium', 500), ('Semibold', 600), ('Bold', 700)):
    if os.path.exists('assets/fonts/MiSans-%s.ttf' % name):
        block += "        - asset: assets/fonts/MiSans-%s.ttf\n          weight: %d\n" % (name, weight)
s = s.replace("flutter:\n  uses-material-design: true\n", "flutter:\n  uses-material-design: true\n" + block, 1)
open('pubspec.yaml', 'w', encoding='utf-8').write(s)
print('MiSans enabled')
