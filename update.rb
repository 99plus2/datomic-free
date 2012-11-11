#!/usr/bin/env ruby

require 'nokogiri'
require 'open-uri'
require 'time'

def datomic_releases
  releases = []
  doc = Nokogiri::HTML(open('http://downloads.datomic.com/free.html'))
  doc.css('table > tbody > tr').each do |trs|
    tds = trs.css('td')
    link = tds[0].css('a').first
    releases.push({
      :url => link[:href],
      :filename => link.content,
      :version => tds[2].content,
      :date => Time.parse(tds[4].content),
    })
  end
  releases
end

def fetch_releases(repo)
  tags = repo.refs(/tags/)
  releases = []

  datomic_releases.each do |release|
    if tag = tags.find { |tag| tag.name.match release[:version] }
      release[:oid] = tag.target
    end
    releases << release
  end

  releases
end

require 'tmpdir'
require 'zip/zip'

def read_zip_files(release)
  zipfile = File.join(Dir.tmpdir, release[:filename])

  if !File.exist?(zipfile)
    warn "Downloading #{release[:url]}"
    File.open(zipfile, 'w+') do |f|
      f.write open(release[:url]).read
    end
  end

  Zip::ZipFile.foreach(zipfile) do |entry|
    if entry.file?
      data = entry.get_input_stream { |io| io.read }
      path = entry.name.split('/', 2)[1]
      yield path, data, entry.unix_perms, entry.time
    end
  end
end

require 'rugged'

def build_release_tree(repo, release)
  warn "Building tree #{release[:filename]}"

  index = repo.index
  index.clear

  read_zip_files(release) do |path, data, mode, time|
    oid = repo.write(data, 'blob')
    index.add({
      :path => path,
      :oid => oid,
      :mode => 0100000 | mode,
      :file_size => 0,
      :dev => 0,
      :ino => 0,
      :uid => 0,
      :gid => 0,
      :mtime => time,
      :ctime => time
    })
  end

  oid = index.write_tree
  warn "tree #{release[:filename]} #{oid}"
  oid
end

def build_commit(repo, release, parent)
  return release[:oid] if release[:oid]

  warn "Building commit #{release[:filename]} #{parent}"

  tree = build_release_tree(repo, release)

  user = {
    :name => "Datomic",
    :email => "info@datomic.com",
    :time => release[:date]
  }
  options = {
    :message => "Datomic #{release[:version]}",
    :author => user,
    :committer => user,
    :tree => tree,
    :parents => parent ? [parent] : []
  }

  oid = Rugged::Commit.create(repo, options)
  warn "commit #{release[:filename]} #{oid}"

  Rugged::Tag.create(repo, {:name => "v#{release[:version]}", :target => oid})
  warn "tag v#{release[:version]} #{oid}"

  oid
end

def update_latest_ref
  repo = Rugged::Repository.new(File.dirname(__FILE__))
  sha = fetch_releases(repo).reverse.inject(nil) do |parent, release|
    build_commit(repo, release, parent)
  end
  Rugged::Reference.create(repo, "refs/heads/latest", sha, true)
  sha
end

puts update_latest_ref
