﻿#include "file_system.h"
#include <cuda.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>

#define DIRSIZE 27648; // 1024 * 27

__device__ __managed__ u32 mod_time = 0;            // store the modify time 
__device__ __managed__ u32 crea_time = 0;           // store the create time
__device__ __managed__ u32 block_pos = 0;           // store the next block location 
__device__ __managed__ u32 FCB_pos = 4096;
__device__ __managed__ u32 current_FCB_pos = 4096; // store the next FCB entry location 

__device__ __managed__ uchar dir[27648];

__device__ __managed__ u32 current_dir = 0;
__device__ __managed__ u32 current_dep = 1;

__device__ __managed__ u32 initcount = 0;


// Tree structure in directory 
// [0] --> represent the whether it is directory 
// [1,2] --> represent the id of the file, which is equal to the index of pcb entry 
// [3,4] --> represent the the id of parent
// [5] --> represent the number of files in diretory 
// [6] --> depth of the directory
// [7,26] --> represent the diretory name 

// structure in each fcb, each fcb has corresponding dir 
// [0,19] --> filename 
// [20,21] --> file location of directory 
// [22,23] --> file modify time 
// [24,27] --> file start block
// [28,31] --> file size  


__device__ void fs_init(FileSystem *fs, uchar *volume, int SUPERBLOCK_SIZE,
							int FCB_SIZE, int FCB_ENTRIES, int VOLUME_SIZE,
							int STORAGE_BLOCK_SIZE, int MAX_FILENAME_SIZE, 
							int MAX_FILE_NUM, int MAX_FILE_SIZE, int FILE_BASE_ADDRESS)
{
  // init variables
  fs->volume = volume;

  // init constants
  fs->SUPERBLOCK_SIZE = SUPERBLOCK_SIZE;
  fs->FCB_SIZE = FCB_SIZE;
  fs->FCB_ENTRIES = FCB_ENTRIES;
  fs->STORAGE_SIZE = VOLUME_SIZE;
  fs->STORAGE_BLOCK_SIZE = STORAGE_BLOCK_SIZE;
  fs->MAX_FILENAME_SIZE = MAX_FILENAME_SIZE;
  fs->MAX_FILE_NUM = MAX_FILE_NUM;
  fs->MAX_FILE_SIZE = MAX_FILE_SIZE;
  fs->FILE_BASE_ADDRESS = FILE_BASE_ADDRESS;

}


__device__ u32 IsFileExist(FileSystem * fs, char *s){
  /* if exist return the FCB position */
  int flag;

  for (int i = 4096; i < 4096 + 32*1024 - 1; i = i + 32){  
    flag = 0;

    /* if size is 0, then stop traverse */
    if (fs->volume[i+28] == 0 &&  fs->volume[i+29] == 0 && fs->volume[i+30] == 0 && fs->volume[i+31] ==0 ){
      break;
    }

    /* search the filename */
    for (int j = 0; j < 20; ++j){
      if (fs->volume[j+i] != s[j]){
        flag =1;
        break;
      }
    }


    /* if exist, return the FCB block location  */
    if (flag == 0){
      u32 parent_dir = (fs->volume[i + 20] << 8) + fs->volume[i+21];
      if (parent_dir != current_dir){
        continue;
      }
      else{
        return i;
      }
    } 

  }

  /* not exist */
  return -1;
}

__device__ bool IsEnoughSpace(FileSystem * fs, u32 fp, u32 size){

  u32 final_block = fp + (size - 1) / 32 ;

  /* the final block position in super */
  u32 super_block_pos = final_block / 8;
  u32 super_block_remain = final_block % 8; 
  u32 temp = fs->volume[super_block_pos] >> super_block_remain;
  return temp % 2 == 0;
}

__device__ u32 Update(FileSystem * fs, u32 fp, u32 size ){

  u32 pos = fs->FILE_BASE_ADDRESS + fp * 32; // the intial position for file 
  u32 required_size = ((size -1)/32 + 1)*32;   // the required space for file including internal fragmentation 

  /* if write the file occupy other file's space, move them */
  while ( (fs->volume[pos + required_size] != 0 || (pos+required_size)%32 != 0) && pos + size < fs->STORAGE_SIZE  ){
    fs->volume[pos] = fs->volume[pos + required_size];
    fs->volume[pos + required_size] = 0;
    pos++;
  }

  /* update the block */
  for (int i = 0; i < block_pos/8 + 1; i++){
    // set it all to zero
    fs->volume[i] = 0;
  }
  block_pos = block_pos - (size-1)/32 -1;
  u32 whole_block = block_pos/8;
  u32 remain = block_pos%8;

  // set the block before to 511(111111111)
  for (int i = 0; i < whole_block && i < fs->SUPERBLOCK_SIZE ; i++) {
		fs->volume[i] = 511;
	}

  // set the remain bit to 0
  for (int i = 0; i < remain; i++) {
		fs->volume[whole_block] = fs->volume[whole_block] + (1 << i); // modify one bit 
	}

  /* modifty the fcb */
  u32 fcb_temp_pos;

  for (int i = 4096; i < 36863; i = i + 32){
    if (fs->volume[i+28] == 0 && fs->volume[i+29] && fs->volume[i+30] ==  0 && fs->volume[i=31] == 0){
      break; // search till empty 
    }
    fcb_temp_pos = (fs->volume[i+24] << 24) + (fs->volume[i+25] << 16)
                  + (fs->volume[i+26] << 8) +  (fs->volume[i+27]);
    if (fcb_temp_pos > fp){
      // clear the external space 
      fcb_temp_pos = fcb_temp_pos - (size-1)/32 - 1;
      fs->volume[i + 24] = fcb_temp_pos >> 24;
      fs->volume[i + 25] = fcb_temp_pos >> 16;
      fs->volume[i + 26] = fcb_temp_pos >> 8;
      fs->volume[i + 27] = fcb_temp_pos;
    }
  }
}


__device__ u32 fs_open(FileSystem *fs, char *s, int op)
{
  u32 ISExist = IsFileExist(fs, s);
  
  /* file not exist */
  if (ISExist == -1){

    /* read mode */
    if (op == 0){
      printf("Open Error: You can not Read file that doesn't exist! \n");
      return -1;
    }

    /* write mode */
    if (op == 1){

      current_FCB_pos = FCB_pos;

      /* store the file name */
      for (int i = 0; i < 20; i++){
        fs->volume[current_FCB_pos + i] = s[i]; 
      }

      /* store the current diretory information */
      fs->volume[FCB_pos + 20] = current_dir >> 8;
      fs->volume[FCB_pos + 21] = current_dir;

      /* store the modify time */
      fs->volume[FCB_pos + 22] = mod_time >> 8;
      fs->volume[FCB_pos + 23] = mod_time;

      /* store the start block */
      fs->volume[FCB_pos + 24] = block_pos >> 24;
      fs->volume[FCB_pos + 25] = block_pos >> 16;
      fs->volume[FCB_pos + 26] = block_pos >> 8;
      fs->volume[FCB_pos + 27] = block_pos;

      /* update the date */
      crea_time++;
      mod_time++;

      /* update the fcb */
      FCB_pos+=32;

      return block_pos;
    }
  }

  /* file exist */
  else{
    
    /* assign the position to current */
    current_FCB_pos = IsFileExist(fs,s);
    u32 start_block = (fs->volume[current_FCB_pos+24] << 24) + (fs->volume[current_FCB_pos+25] << 16) 
                  +(fs->volume[current_FCB_pos+26] << 8) + (fs->volume[current_FCB_pos+27] );

    /* write mode */
    if (op == 1){
      u32 filesize = (fs->volume[current_FCB_pos+28] << 24) + (fs->volume[current_FCB_pos+29] << 16)
                    +(fs->volume[current_FCB_pos+30] << 8) + (fs->volume[current_FCB_pos+31]);

      /* clean the old file in disk */
      for (int i = 0; i < filesize; ++i){
        fs->volume[fs->FILE_BASE_ADDRESS + start_block * 32 + i] = 0;
      }
      
      /* update the super block */
      for (int i = 0; i < (filesize -1)/32 + 1; i++){
        u32 super_block = start_block + i;
        int shiftnum = super_block % 8;
        fs->volume[super_block/8] = fs->volume[super_block/8] - (1 << shiftnum); // modify one bit
      }

      
      /* update fcb */
      fs->volume[current_FCB_pos + 22] =  mod_time >> 8;
      fs->volume[current_FCB_pos + 23] = mod_time;
      
      mod_time++;

    }
    // printf("start block is %d  \n ", start_block);
    // printf("in open is .. %c \n", fs->volume[4096]);
    return start_block;
  }
}


__device__ void fs_read(FileSystem *fs, uchar *output, u32 size, u32 fp)
{
	
  for (int i = 0; i < size; ++i){
    output[i] = fs->volume[fp * 32 + i + fs->FILE_BASE_ADDRESS];
  }

}

__device__ u32 fs_write(FileSystem *fs, uchar* input, u32 size, u32 fp)
{
  
  /* if enough space to write */
  if ( IsEnoughSpace(fs,fp,size) ){

    for (int i = 0; i < size; ++i){
      /* update the disk */
      fs->volume[fs->FILE_BASE_ADDRESS + fp * 32 + i] = input[i];
      /* update the super block */
      if ( i % 32 == 0){
        u32 super_block = fp + i/32;
        int shiftnum = super_block % 8;
        fs->volume[super_block/8] = fs->volume[super_block/8] + (1 << shiftnum); // modify one bit
      }
    }

    u32 pre_file_size =  (fs->volume[current_FCB_pos + 28] << 24) + (fs->volume[current_FCB_pos + 29] << 16)
                        +(fs->volume[current_FCB_pos + 30] << 8) + (fs->volume[current_FCB_pos + 31]);
    
    /**/
    u32 delta_size = pre_file_size - size;
    
    
    if ((int) delta_size < 0 ){
      block_pos = block_pos + (-delta_size - 1)/32 + 1;
    }

    /* update the size */
    fs->volume[current_FCB_pos + 28] = size >> 24;
    fs->volume[current_FCB_pos + 29] = size >> 16;
    fs->volume[current_FCB_pos + 30] = size >> 8;
    fs->volume[current_FCB_pos + 31] = size;

    


    if (delta_size > 0 && pre_file_size != 0 && fp != block_pos - 1){
      Update(fs, fp + (size -1)/32 + 1 , delta_size);
    }
    // printf(" current block is %d \n", block_pos);
    
  }

  /* not enough space */
  else{
    
    if (block_pos * 32 - 1 + size >= fs->SUPERBLOCK_SIZE){
      printf("Write Error: you Write the file out of limited space \n");
      return -1;
    }

    /* write the file into new space */
    for ( int i = 0; i < size; ++i){

      fs->volume[fs->FILE_BASE_ADDRESS + block_pos * 32 + i] = input[i];

      /* update the super block */
      if ( i % 32 == 0){
        u32 super_block = block_pos + i/32;
        int shiftnum = super_block % 8;
        fs->volume[super_block/8] = fs->volume[super_block/8] + (1 << shiftnum); // modify one bit
      }
    }

    /* update the size */
    fs->volume[current_FCB_pos + 28] = size >> 24;
    fs->volume[current_FCB_pos + 29] = size >> 16;
    fs->volume[current_FCB_pos + 30] = size >> 8;
    fs->volume[current_FCB_pos + 31] = size;

    /* uodate the start position */
    fs->volume[current_FCB_pos + 24] = block_pos >> 24;
    fs->volume[current_FCB_pos + 25] = block_pos >> 16;
    fs->volume[current_FCB_pos + 26] = block_pos >> 8;
    fs->volume[current_FCB_pos + 27] = block_pos;

    u32 pre_file_size = (fs->volume[current_FCB_pos + 28] << 24) + (fs->volume[current_FCB_pos + 29] << 16) 
                        +(fs->volume[current_FCB_pos + 30] << 8) + (fs->volume[current_FCB_pos + 31]);
    
    Update(fs, fp , pre_file_size);
  }

}

__device__ void swap(FileSystem * fs, u32 pre, u32 after){
  for (int i = 0; i < 32; i++){
    uchar temp = fs->volume[pre + i];
		fs->volume[pre + i] = fs->volume[after + i];
		fs->volume[after + i] = temp;
  }
}

__device__ void Sort(FileSystem *  fs, u32 begin, u32 end, int op){
  
  
  if (op == 0){
    for ( int i = begin; i < end + 32; i += 32){
      for ( int j = begin; j < end - i + begin + 32; j += 32 ){
        u32 previous_date =  (fs->volume[j + 22] << 8) + (fs->volume[j + 23]);
				u32 after_date = (fs->volume[j + 22 + 32] << 8) + (fs->volume[j + 23 + 32]);
				if ( previous_date < after_date ) swap(fs, j, j + 32);
        
      }
    }
  }

  else{
    for (int i = begin; i < end + 32; i += 32 ){
      for ( int j = begin; j < end -i + begin + 32; j += 32){
        u32 pre_size = (fs->volume[j + 28] << 24) + (fs->volume[j + 29] << 16)
                      +(fs->volume[j + 30] << 8)  + (fs->volume[j + 31]);
        u32 after_size =  (fs->volume[j + 28 + 32] << 24) + (fs->volume[j + 29 + 32] << 16)
                          +(fs->volume[j + 30 + 32] << 8)  + (fs->volume[j + 31 + 32]);

        u32 pre_creadate =  (fs->volume[j + 20] << 8) + (fs->volume[j + 21]);
        u32 after_creadate = (fs->volume[j + 20 + 32] << 8) + (fs->volume[j + 21 + 32]);

        if (pre_size < after_size || (pre_size == after_size && pre_creadate > after_creadate )){
          swap(fs, j , j+32);
        }
        
      }
    }
  }
}

__device__ void Print(FileSystem * fs, u32 stop_pos, int op){
  char result[20];

  if ( op == 0){
    printf("===sort by modified time===\n");
    for (int i = 4096; i < stop_pos + 32; i+=32){
      int flag = 0;
      for (int j = 0; j < 20; j++){
        result[j] = fs->volume[j+i];
        u32 parent_dir = (fs->volume[i + 20] << 8) + fs->volume[i+21];
        if (parent_dir != current_dir) result[j] = flag = 1;
      }
      if (flag == 0)printf("%s\n",result);
    }
  }


  else{
    u32 temp;
    printf("===sort by file size===\n");
    for (int i = 4096; i < stop_pos + 32; i+=32){
      int flag = 0;
      for (int j = 0; j < 20; j++){
        result[j] = fs->volume[j+i];
        u32 parent_dir = (fs->volume[i + 20] << 8) + fs->volume[i+21];
        if (parent_dir != current_dir) flag =1 ;
      }
      temp = (fs->volume[i+28] << 24) + (fs->volume[i+29] << 16)
            +(fs->volume[i+30] << 8) + (fs->volume[i+31]);

      if (flag == 0) printf("%s %d \n", result,temp );
    }
  }

  for( int i = 0; i < 1024*27 -1 ; i += 27){
    if (dir[i+7] == 0) break;
    u32 parent_dir = (dir[i + 3] << 8) + dir[i+4];
    if (parent_dir == current_dir){
      for(int j = 0; j < 20; j++){
        if(dir[i+7+j] != 0) printf("%c", dir[i+7+j]);
      }
      printf("d\n");
    }
  }

}


__device__ void fs_gsys(FileSystem *fs, int op)
{

  /* CD_P*/
  if (op == 8){

    for (int i = 0; i < 20; i++){
      printf("%c", dir[current_dir + 7 +i]);
    }
    int flag;
    for (int i = 0; i < 1024*27-1; i +=27){
      flag =0;
      if (dir[i] == 0) break;

      for (int j = 0; j < 20; j++){
        if (dir[i+7+j] != dir[current_dir +7+ j]) flag =1;
      }

      if (flag == 0){
        u32 parentid = (dir[i + 3] << 8) + dir[i + 4];
        current_dir = parentid;
      }

    }
  }

	/* PWD */
  if (op == 7){
    int mylist[3];
    int size = 0;
    int id = current_dir;
    
    while (id != 0){
      mylist[size++] = id; 
      id = (dir[id + 3] << 8) + dir[id + 4]; // parent id 
    }

    if (size == 0){
      printf("/");
    }
    while (size > 0){
      id = mylist[--size];
      printf("/");
      for (int i = 0; i < 20; i++){
        
        if (dir[id + 7 +i] == 0) break;
        else{
          printf("%c",dir[id+7+i]);
        }
      }
    }
    printf("\n");
  }

  /* LS_D and LS_S */
  else{
    u32 stop_pos;

    /* search the stop point */
    for ( int i = 4096 ; i < (4096 + 32*1024 - 1); i += 32 ){
      u32 file_size = (fs->volume[i + 28] <<  24) + (fs->volume[i + 29] <<  16) 
                      +(fs->volume[i + 30] <<  8)  + (fs->volume[i + 31]);

      if (file_size == 0) break;
      stop_pos = i ;
    }


    if (stop_pos <=  4096){
      printf("LS Error: No file in FCB \n");
    }

    Sort(fs, 4096, stop_pos, op);
    Print(fs, stop_pos, op);
  }

}



__device__ void fs_gsys(FileSystem *fs, int op, char *s)
{ 
  /* initialize the ROOT directory */
  if (initcount == 0){
    dir[0] = 1; // represent the root directory 
    dir[1] = 0;
    dir[2] = 0; 
    dir[3] = 1024 >> 8; // set the root parent to 1024 since no id would be 1024
    dir[4] =  1024; 
    dir[5] = 0; // number of file 
    dir[6] = 0; // depth 
    dir[7] = '/';
    dir[8] = '\0';
    initcount++; // only init once 
  }

  /* MKDIR */
  if (op == 3){
    u32 myid;
    for (int i  = 0; i < 1024*27-1; i += 27){
      if (dir[i+7] == 0){
        myid = i;
        break;
      }
    }
    dir[myid] = 1; // represent dir
    dir[myid + 1] = myid >> 8;
    dir[myid + 2]= myid;
    dir[myid + 3]= current_dir >> 8;
    dir[myid + 4]= current_dir;
    dir[myid + 5] = 0; //number of file 
    dir[myid + 6] = current_dep;
    for (int j = 0; j < 20; j++){
      dir[myid + 7 +j] = s[j];
    }
  }

  /* CD */
  if ( op == 4){
    int flag;
    for (int i = 0; i < 1024*27 -1; i+=27){
      flag = 0;
      if (dir[i] == 0) break;
      for (int j = 0; j < 20; j++){
        if (dir[i + 7 +j] != s[j]) flag =1;
      }

      if (flag == 0){
        int parentid = (dir[i + 3] << 8) + dir[i + 4];
        if (parentid == current_dir){
          current_dir = (dir[i + 1] << 8) + dir[i+2];
        }
      }
    }
  }

  /* RM */
  if (op == 2){
    u32 ISExist = IsFileExist(fs, s);

    if ((int) ISExist == -1){
      printf("Remove Error: No Such file! \n");
      return;
    }

    else{
      /* search*/
      current_FCB_pos = ISExist;

      u32 start_block = (fs->volume[current_FCB_pos + 24] << 24) + (fs->volume[current_FCB_pos + 25] << 16)
                      + (fs->volume[current_FCB_pos + 26] << 8) + (fs->volume[current_FCB_pos + 27]);

      u32 file_size = (fs->volume[current_FCB_pos + 28] << 24) + (fs->volume[current_FCB_pos + 29] << 16)
                    + (fs->volume[current_FCB_pos + 30] << 8) + (fs->volume[current_FCB_pos + 31]);

      u32 block_size = (file_size - 1) / 32 + 1;
      for (int i = 0; i < block_size; i++){
        fs->volume[start_block + i ] = 0;
      }

      for (int i = 0; i < file_size; i ++){
        fs->volume[start_block * 32 + i + fs->FILE_BASE_ADDRESS] = 0;
      }

      Update(fs, start_block, file_size);

      for (int i = current_FCB_pos; i < (4096 + 32*1024 - 1); i += 32){
        u32 size = (fs->volume[i + 28] << 24) + (fs->volume[i + 29] << 16)
                  +(fs->volume[i + 30] << 8) + (fs->volume[i + 31]);
        if (size == 0) break;
        for (int j = 0; j < 32; j++){
          fs->volume[i + j] = fs->volume[i + j + 32];
          fs->volume[i + j + 32] = 0;
        }
      }

      FCB_pos -= 32;
    }
  }

  /* RM_RF*/
  if (op == 6){
    /* represent the index of directory in dir block */
    int index = -1;

    for (int i = 0; i < 1024*27-1; i+=27){
      int flag = 0;

      if (dir[i] = 0) break;

      for (int j = 0; j < 20; j++){
        if(dir[i+7+j] != s[j]) flag =1;
      }

      if (flag = 0){
        int parentid = (dir[i + 3] << 8) + dir[i + 4];
        /* if paraent = current, then found */
        if(parentid == current_dir){
          index = i;
        }
      }
    }

    if (index != -1){
      // I did not finish the update part 
      // I need traverse the tree and find the all the dir that root is "soft"
      // and remove all the file in the file block that realted to "soft"
      // Finally I need to clear the external fragmentation 
      // I have many bugs here and I did not finish it until deadline
    }
  }

  
}
