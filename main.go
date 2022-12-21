package main

import (
	"bytes"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"

	"github.com/Shopify/ejson"
	"github.com/geofffranks/spruce"
	jsoniter "github.com/json-iterator/go"
	"github.com/spf13/viper"
	"gopkg.in/src-d/go-billy.v4"
	"gopkg.in/src-d/go-billy.v4/memfs"
	"gopkg.in/yaml.v3"
	"sigs.k8s.io/kustomize/api/konfig"
	"sigs.k8s.io/kustomize/api/types"
)

// config
type config struct {
	TmpDir                string   `mapstructure:"TMP_DIR"`
	RootDirectory         string   `mapstructure:"ROOT_DIRECTORY"`
	ExtraDirectories      []string `mapstructure:"EXTRA_DIRECTORIES"`
	EjsonFileRegex        string   `mapstructure:"EJSON_FILE_REGEX"`
	EjsonSecret           string   `mapstructure:"EJSON_SECRET"`
	EjsonInline           string   `mapstructure:"EJSON_INLINE_KEYS"`
	VarFileRegex          string   `mapstructure:"VAR_FILE_REGEX"`
	KustomizeBuildOptions string   `mapstructure:"KUSTOMIZE_BUILD_OPTIONS"`
}

var c config
var paths []string
var keys []string
var tmp string
var vfs billy.Filesystem

func main() {
	configure()
	// merge extra_directories and root directories
	paths = append(c.ExtraDirectories, c.RootDirectory)

	// read kustomization resources and add path
	kz, err := readKustomize()
	if err != nil {
		log.Println(err)
		os.Exit(2)
	}
	paths = append(paths, kz.Resources...)

	// TODO: Secret get from kubernetes secrets

	// decrypt ejosn files
	keys = append(keys, c.EjsonSecret)
	err = filepath.Walk(c.RootDirectory, decryptEjsonFiles)
	if err != nil {
		fmt.Println(err)
		os.Exit(3)
	}

	// merge all together with spruce
	m := make(map[interface{}]interface{})

	filepath.Walk(c.RootDirectory, func(path string, info fs.FileInfo, err error) error {
		if info.IsDir() {
			return err
		}
		file, err := vfs.Open(path)
		if err != nil {
			fmt.Println("hi", err)
			os.Exit(1)
		}
		filebyte, err := io.ReadAll(file)
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
		tmp := make(map[interface{}]interface{})
		_ = yaml.Unmarshal(filebyte, &tmp)
		m, err = spruce.Merge(m, tmp)
		return err
	})
	a, _ := jsoniter.MarshalIndent(m, "", " ")
	fmt.Println(string(a))

}

func decryptEjsonFiles(path string, info os.FileInfo, err error) error {
	if filepath.Ext(path) == c.EjsonFileRegex {
		// found file decrypt it to tmp dir
		decrypt, _ := ejson.DecryptFile(path, "", keys[0])
		file, err := vfs.Create(path)
		if err != nil {
			return err
		}
		decryptReader := bytes.NewReader(decrypt)
		_, err = io.Copy(file, decryptReader)
		if err != nil {
			return err
		}
		return err
	}

	return err
}

func configure() {
	v := viper.New()
	// configure defaults
	v.SetDefault("TMP_DIR", "/tmp")
	v.SetDefault("KUSTOMIZE_BUILD_OPTIONS", "")
	v.SetDefault("ROOT_DIRECTORY", ".")
	v.SetDefault("EXTRA_DIRECTORIES", os.Getenv("ARGOCD_ENV_EXTRA_DIRECTORIES"))
	v.SetDefault("EJSON_FILE_REGEX", ".ejson")
	v.SetDefault("EJSON_SECRET", os.Getenv("ARGOCD_ENV_SECRET"))
	v.SetDefault("EJSON_INLINE_KEYS", "")
	v.SetDefault("VAR_FILE_REGEX", "*.vars")
	v.AutomaticEnv()

	err := v.Unmarshal(&c)
	if err != nil {
		fmt.Println(err)
	}
	v.Unmarshal(&c)
	// create a memory filesystem
	vfs = memfs.New()
	filepath.Walk(c.RootDirectory, func(path string, info fs.FileInfo, err error) error {
		if info.IsDir() {
			return err
		}
		src, _ := os.OpenFile(path, os.O_RDONLY, os.ModePerm)
		dst, err := vfs.Create(path)
		if err != nil {
			fmt.Println(err)
			os.Exit(1)
		}
		io.Copy(dst, src)
		return err
	})

}

func readKustomize() (types.Kustomization, error) {
	kz := types.Kustomization{}
	for _, kfilename := range konfig.RecognizedKustomizationFileNames() {
		if _, err := os.Stat(kfilename); err == nil {
			kzBytes, err := os.ReadFile(kfilename)
			if err != nil {
				return kz, err
			}
			err = kz.Unmarshal(kzBytes)

			return kz, err
		}
	}
	return kz, fmt.Errorf("no kustomization file found")
}
