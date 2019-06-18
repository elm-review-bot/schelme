extern crate serde_json;
use failure;
use failure::Error;
use serde_json::Value;
// use std::fs::File;
use std::fs;
use std::io::Read;
use std::path::Path;
use util;

#[derive(Deserialize, Debug)]
pub struct PublicMessage {
  what: String,
  data: Option<serde_json::Value>,
}

#[derive(Deserialize, Debug)]
pub struct Message {
  pub uid: String,
  pwd: String,
  what: String,
  data: Option<serde_json::Value>,
}

#[derive(Deserialize, Debug)]
pub struct SaveScript {
  name: String,
  script: String,
}

#[derive(Serialize, Deserialize)]
pub struct ServerResponse {
  pub what: String,
  pub content: Value,
}

fn load_script(name: &str) -> Result<ServerResponse, Error> {
  Ok(ServerResponse {
    what: "script".to_string(),
    content: serde_json::from_str(
      util::load_string(format!("scripts/{}", name).as_str())?.as_str(),
    )?,
  })
}

fn save_script(name: &str, script: &str) -> Result<ServerResponse, Error> {
  // how many scripts have we?
  let tbdir = Path::new("scripts/");
  let fc = fs::read_dir(tbdir)?.count();
  if fc < 500 {
    util::write_string(
      format!("scripts/{}", name).as_str(),
      script
    )?;

    Ok(ServerResponse {
      what: "script written!".to_string(),
      content: serde_json::Value::Null,
    })
  } else {
    Err(failure::err_msg("too many scripts, can't save!"))
  }
}

// public json msgs don't require login.
pub fn process_public_json(
  ip: &Option<&str>,
  msg: PublicMessage,
) -> Result<Option<ServerResponse>, Error> {
  match msg.what.as_str() {
    "getscript" => match msg.data {
      None => Ok(Some(ServerResponse {
        what: "no script specified!".to_string(),
        content: serde_json::Value::Null,
      })),
      Some(data) => {
        info!("public getscript:{}", data);
        match data.to_string().as_str() {
          name => (load_script(name)).map(Some),
        }
      }
    },

    "savescript" => match msg.data {
      None => Ok(Some(ServerResponse {
        what: "no script specified!".to_string(),
        content: serde_json::Value::Null,
      })),
      Some(data) => {
        info!("public getscript:{}", data);
        let blah: SaveScript = serde_json::from_value(data)?;
        save_script(blah.name.as_str(), & blah.script).map(Some)
          
      }
    },

    "getscriptlist" => Ok(Some(ServerResponse {
      what: "scriptlist".to_string(),
      content: serde_json::to_value(script_list()?)?,
    })),
    wat => Err(failure::err_msg(format!("invalid 'what' code:'{}'", wat))),
  }
}

pub fn script_list() -> Result<Vec<String>, Error> {
  // find all script files.
  let tbdir = Path::new("scripts/");
  let mut scriptnames = Vec::new();

  if tbdir.is_dir() {
    fs::read_dir(tbdir)?.for_each(|b| match b {
      Ok(c) => {
        c.path().file_stem().map(|os| {
          os.to_str().map(|s| scriptnames.push(s.to_string()));
        });
      }
      Err(_) => (),
    });
    Ok(scriptnames)
  } else {
    Err(failure::err_msg("scripts/ is not a directory!"))
  }
}
