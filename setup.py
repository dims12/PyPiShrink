from setuptools import setup, find_packages

with open("README.md", "r", encoding="utf-8") as f:
    long_description = f.read()


setup(
    name='PyPiShrink',
    version='0.1.2',
    long_description=long_description,
    long_description_content_type='text/markdown',
    packages=find_packages(),
    scripts=['pypishrink'],
    install_requires=[
        'NormalPyRunner'
    ],
)